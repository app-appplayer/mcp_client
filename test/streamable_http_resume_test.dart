/// Streamable HTTP client behaviour against a scripted server: priming
/// events and `retry`, resuming a lost request stream with Last-Event-ID,
/// and starting a new session after 404.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

typedef _Handler = Future<void> Function(HttpRequest request, Map? body);

Future<(HttpServer, List<String>)> _serve(_Handler handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final log = <String>[];
  server.listen((request) async {
    final text = await utf8.decoder.bind(request).join();
    final body = text.isEmpty ? null : jsonDecode(text) as Map;
    log.add('${request.method} ${body?['method'] ?? body?['id'] ?? ''} '
        'session=${request.headers.value('mcp-session-id')} last=${request.headers.value('last-event-id')}');
    await handler(request, body);
  });
  return (server, log);
}

Map<String, dynamic> _initResult(Object id) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': '2025-11-25',
        'serverInfo': {'name': 's', 'version': '1'},
        'capabilities': {'tools': <String, dynamic>{}},
      },
    };

Future<void> _json(HttpRequest r, Object body, {String? session}) async {
  r.response.headers.contentType = ContentType.json;
  if (session != null) r.response.headers.set('mcp-session-id', session);
  r.response.write(jsonEncode(body));
  await r.response.close();
}

Future<void> _accepted(HttpRequest r) async {
  r.response.statusCode = 202;
  await r.response.close();
}

void main() {
  test('a request stream lost before its response is resumed with Last-Event-ID', () async {
    late Object toolCallId;
    final (server, log) = await _serve((r, body) async {
      if (r.method == 'POST' && body?['method'] == 'initialize') return _json(r, _initResult(body!['id']), session: 'S1');
      if (r.method == 'POST' && body?['method'] == 'tools/call') {
        toolCallId = body!['id'];
        // Priming event with retry, then the connection drops.
        r.response.headers.set('content-type', 'text/event-stream');
        r.response.write('id: stream-1\nretry: 50\ndata: \n\n');
        await r.response.flush();
        await r.response.close();
        return;
      }
      if (r.method == 'GET' && r.headers.value('last-event-id') == 'stream-1') {
        r.response.headers.set('content-type', 'text/event-stream');
        r.response.write('id: stream-2\ndata: ${jsonEncode({'jsonrpc': '2.0', 'id': toolCallId, 'result': {'content': [{'type': 'text', 'text': 'resumed'}]}})}\n\n');
        await r.response.close();
        return;
      }
      if (r.method == 'GET') {
        r.response.statusCode = 405;
        return r.response.close();
      }
      return _accepted(r);
    });
    addTearDown(() => server.close(force: true));
    final client = Client(name: 'c', version: '1');
    await client.connect(await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.legacy);
    addTearDown(client.disconnect);
    final result = await client.callTool('t', const {});
    expect((result.content.single as TextContent).text, 'resumed');
    expect(log.where((l) => l.startsWith('GET') && l.contains('last=stream-1')), hasLength(1));
  });

  test('a 404 for the session starts a new session and retries the request', () async {
    var sessions = 0;
    final (server, log) = await _serve((r, body) async {
      if (r.method == 'POST' && body?['method'] == 'initialize') {
        sessions++;
        return _json(r, _initResult(body!['id']), session: 'S$sessions');
      }
      if (r.method == 'POST' && body?['method'] == 'tools/list') {
        if (r.headers.value('mcp-session-id') == 'S1') {
          r.response.statusCode = 404;
          return r.response.close();
        }
        return _json(r, {'jsonrpc': '2.0', 'id': body!['id'], 'result': {'tools': []}});
      }
      if (r.method == 'GET') {
        r.response.statusCode = 405;
        return r.response.close();
      }
      return _accepted(r);
    });
    addTearDown(() => server.close(force: true));
    final client = Client(name: 'c', version: '1');
    await client.connect(await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.legacy);
    addTearDown(client.disconnect);
    expect(await client.listTools(), isEmpty);
    expect(sessions, 2);
    // The new initialize carries no session id.
    expect(log.where((l) => l.startsWith('POST initialize')).last, contains('session=null'));
  });

  test('the GET stream reconnects with the last event id after the server closes it', () async {
    var gets = 0;
    final (server, log) = await _serve((r, body) async {
      if (r.method == 'POST' && body?['method'] == 'initialize') return _json(r, _initResult(body!['id']), session: 'S');
      if (r.method == 'GET') {
        gets++;
        r.response.headers.set('content-type', 'text/event-stream');
        if (gets == 1) {
          r.response.write('id: g-1\nretry: 30\ndata: \n\n');
          r.response.write('id: g-2\ndata: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'})}\n\n');
        }
        await r.response.close();
        return;
      }
      return _accepted(r);
    });
    addTearDown(() => server.close(force: true));
    final client = Client(name: 'c', version: '1');
    final changed = Completer<void>();
    client.onNotification('notifications/tools/list_changed', (_) {
      if (!changed.isCompleted) changed.complete();
    });
    await client.connect(await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.legacy);
    addTearDown(client.disconnect);
    await changed.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(log.where((l) => l.startsWith('GET') && l.contains('last=g-2')), isNotEmpty);
  });

  test('2026-07-28: tools with invalid x-mcp-header are left out of tools/list', () async {
    final (server, _) = await _serve((r, body) async {
      if (body?['method'] == 'tools/list') {
        return _json(r, {
          'jsonrpc': '2.0',
          'id': body!['id'],
          'result': {
            'resultType': 'complete',
            'tools': [
              {'name': 'good', 'inputSchema': {'type': 'object', 'properties': {'r': {'type': 'string', 'x-mcp-header': 'R'}}}},
              {'name': 'bad', 'inputSchema': {'type': 'object', 'properties': {'n': {'type': 'number', 'x-mcp-header': 'N'}}}},
            ],
          },
        });
      }
      return _accepted(r);
    });
    addTearDown(() => server.close(force: true));
    final client = Client(name: 'c', version: '1');
    await client.connect(await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.modern);
    addTearDown(client.disconnect);
    expect((await client.listTools()).map((t) => t.name), ['good']);
  });

  test('2026-07-28: a broken response stream is re-issued once with a new id', () async {
    final callIds = <Object>[];
    final (server, _) = await _serve((r, body) async {
      final method = body?['method'];
      if (method == 'tools/list') {
        return _json(r, {'jsonrpc': '2.0', 'id': body!['id'], 'result': {
          'resultType': 'complete',
          'tools': [{'name': 't', 'inputSchema': {'type': 'object'}}],
        }});
      }
      if (method == 'tools/call') {
        callIds.add(body!['id']);
        if (callIds.length == 1) {
          // The stream opens, then breaks before the response.
          r.response.headers.set('content-type', 'text/event-stream');
          r.response.write(': keepalive\n\n');
          await r.response.flush();
          await r.response.close();
          return;
        }
        return _json(r, {'jsonrpc': '2.0', 'id': body['id'], 'result': {
          'resultType': 'complete',
          'content': [{'type': 'text', 'text': 'second try'}],
        }});
      }
      return _accepted(r);
    });
    addTearDown(() => server.close(force: true));
    final client = Client(name: 'c', version: '1');
    await client.connect(await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.modern);
    addTearDown(client.disconnect);
    final result = await client.callTool('t', const {});
    expect((result.content.single as TextContent).text, 'second try');
    expect(callIds, hasLength(2));
    expect(callIds.toSet(), hasLength(2), reason: 'the re-issue has a new id');
  });
}
