/// `TransportConfig.sse` opens the standard HTTP+SSE transport (bearer token
/// on the stream and on every POST, events parsed by the event-stream rules),
/// and heartbeats are `ping`s that end the connection only after
/// `maxMissedHeartbeats` misses in a row.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

/// A 2024-11-05 HTTP+SSE server: records the Authorization header of every
/// request, answers initialize, and sends two events in one chunk after it.
Future<({int port, List<String?> auth})> _sseServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final auth = <String?>[];
  HttpResponse? stream;
  server.listen((r) async {
    auth.add(r.headers.value('authorization'));
    if (r.method == 'GET') {
      stream = r.response
        ..headers.contentType = ContentType('text', 'event-stream')
        ..bufferOutput = false;
      stream!.write('event: endpoint\ndata: /messages\n\n');
      await stream!.flush();
      return;
    }
    final message = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
    r.response.statusCode = HttpStatus.accepted;
    await r.response.close();
    if (message['method'] == 'initialize') {
      stream!.write('event: message\ndata: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'protocolVersion': '2024-11-05',
              'capabilities': {'tools': {'listChanged': true}},
              'serverInfo': {'name': 's', 'version': '1'},
            },
          })}\n\n');
      await stream!.flush();
    } else if (message['method'] == 'tools/list') {
      // The result and a notification in one chunk.
      stream!.write('event: message\ndata: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {'tools': []},
          })}\n\n'
          'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n\n');
      await stream!.flush();
    }
  });
  return (port: server.port, auth: auth);
}

void main() {
  test('the bearer token rides the stream and every POST; events in one chunk all arrive', () async {
    final s = await _sseServer();
    final changed = Completer<void>();
    final result = await McpClient.createAndConnect(
      config: McpClient.simpleConfig(name: 'c', version: '1').copyWith(era: ProtocolEra.legacy),
      transportConfig: TransportConfig.sse(serverUrl: 'http://127.0.0.1:${s.port}/sse', bearerToken: 'tok'),
    );
    final client = result.fold((c) => c, (e) => throw e);
    addTearDown(client.disconnect);
    client.onToolsListChanged(() {
      if (!changed.isCompleted) changed.complete();
    });
    expect(client.negotiatedProtocolVersion, '2024-11-05');
    expect(await client.listTools(), isEmpty);
    await changed.future.timeout(const Duration(seconds: 5));
    expect(s.auth, isNotEmpty);
    expect(s.auth, everyElement('Bearer tok'));
  });

  test('keep-alive disconnects only after maxMissed unanswered pings in a row', () async {
    final transport = MockTransport();
    transport.queueResponse({
      'jsonrpc': '2.0',
      'id': 1,
      'result': {
        'protocolVersion': McpProtocol.v2025_03_26,
        'serverInfo': {'name': 's', 'version': '1'},
        'capabilities': {},
      },
    });
    final client = Client(name: 'c', version: '1');
    await client.connect(transport, era: ProtocolEra.legacy);
    final pings = <Object?>[];
    var answer = true;
    transport.onSend = (m) {
      if (m is Map && m['method'] == 'ping') {
        pings.add(m['id']);
        if (answer) {
          scheduleMicrotask(() => transport.simulateMessage({'jsonrpc': '2.0', 'id': m['id'], 'result': {}}));
        }
      }
    };
    final reasons = <DisconnectReason>[];
    client.onDisconnect.listen(reasons.add);
    client.startKeepAlive(const Duration(milliseconds: 40),
        timeout: const Duration(milliseconds: 20), maxMissed: 3);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(reasons, isEmpty, reason: 'answered pings keep it up');
    answer = false;
    final before = pings.length;
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(reasons, isEmpty, reason: 'two misses are not yet three');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reasons, [DisconnectReason.pingTimeout]);
    expect(pings.length - before, greaterThanOrEqualTo(3));
  });
}
