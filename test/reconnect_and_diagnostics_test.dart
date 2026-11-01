/// What a client does across connections, and what it tells the caller when a
/// connection ends: nothing is answered twice after a reconnect, a server
/// process that dies says why, and a stream the server pushes on is reopened.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

Map<String, dynamic> _initResponse() => {
      'jsonrpc': '2.0',
      'result': {
        'protocolVersion': '2025-11-25',
        'serverInfo': {'name': 's', 'version': '1'},
        'capabilities': {'tools': {'listChanged': true}},
      },
    };

void main() {
  group('reconnecting the same client', () {
    test('a notification is handled once per message, however often it connected before', () async {
      final client = Client(name: 'c', version: '1');
      var handled = 0;
      client.onToolsListChanged(() => handled++);

      for (var round = 1; round <= 4; round++) {
        final transport = MockTransport()..queueResponse(_initResponse());
        await client.connect(transport, era: ProtocolEra.legacy);
        handled = 0;
        transport.simulateMessage({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'});
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(handled, 1, reason: 'connection $round');
        client.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('a server request (sampling) is answered once per request after reconnecting', () async {
      final client = Client(name: 'c', version: '1', capabilities: const ClientCapabilities(sampling: true));
      var asked = 0;
      client.onSamplingRequestMap((params) async {
        asked++;
        return {
          'role': 'assistant',
          'content': {'type': 'text', 'text': 'ok'},
          'model': 'm',
        };
      });

      for (var round = 1; round <= 3; round++) {
        final transport = MockTransport()..queueResponse(_initResponse());
        await client.connect(transport, era: ProtocolEra.legacy);
        asked = 0;
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'id': 'srv-$round',
          'method': 'sampling/createMessage',
          'params': {
            'messages': [
              {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
            ],
            'maxTokens': 10,
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(asked, 1, reason: 'connection $round: one request, one model call');
        client.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  });

  group('stdio servers that fail', () {
    test('a server that dies at start-up says why: exit code and what it wrote to stderr', () async {
      final client = Client(name: 'c', version: '1');
      final transport = await StdioClientTransport.create(
        command: 'sh',
        arguments: ['-c', 'echo "fatal: OPENAI_API_KEY is not set" >&2; exit 3'],
      );
      Object? failure;
      try {
        await client.connect(transport, era: ProtocolEra.legacy);
      } catch (e) {
        failure = e;
      }
      expect(failure, isA<McpError>());
      final text = '$failure';
      expect(text, contains('code 3'));
      expect(text, contains('OPENAI_API_KEY is not set'));
      expect(transport.exitCode, 3);
    }, testOn: '!windows');

    test('the server\'s stderr can be read as it is written', () async {
      final transport = await StdioClientTransport.create(
        command: 'sh',
        arguments: ['-c', 'echo "starting" >&2; sleep 1'],
      );
      addTearDown(transport.close);
      final first = await transport.stderr.first.timeout(const Duration(seconds: 5));
      expect(first, 'starting');
    }, testOn: '!windows');

    test('a closed transport does not blame the server', () async {
      final transport = await StdioClientTransport.create(command: 'sh', arguments: ['-c', 'sleep 5']);
      transport.close();
      await transport.onClose.timeout(const Duration(seconds: 10));
      expect(transport.closeReason, isNull, reason: 'we closed it: there is no failure to explain');
    }, testOn: '!windows');

    test('a byte that is not UTF-8 on the server\'s output does not end the connection', () async {
      final transport = await StdioClientTransport.create(
        command: 'sh',
        arguments: [
          '-c',
          r'printf "\377\376 noise\n"; printf "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}\n"; sleep 2',
        ],
      );
      addTearDown(transport.close);
      final message = await transport.onMessage.first.timeout(const Duration(seconds: 10));
      expect((message as Map)['method'], 'notifications/x');
    }, testOn: '!windows');
  });

  group('Streamable HTTP push stream', () {
    test('a GET stream that could not be opened is tried again', () async {
      final getAttempts = <int>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        final body = text.isEmpty ? null : jsonDecode(text) as Map;
        if (request.method == 'POST' && body?['method'] == 'initialize') {
          request.response.headers.contentType = ContentType.json;
          request.response.headers.set('mcp-session-id', 'S1');
          request.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': body!['id'],
            'result': {
              'protocolVersion': '2025-11-25',
              'serverInfo': {'name': 's', 'version': '1'},
              'capabilities': {'tools': {'listChanged': true}},
            },
          }));
          await request.response.close();
        } else if (request.method == 'POST') {
          request.response.statusCode = 202;
          await request.response.close();
        } else if (request.method == 'GET') {
          getAttempts.add(getAttempts.length + 1);
          if (getAttempts.length == 1) {
            // the connection breaks before any response: the client sees a network error
            final socket = await request.response.detachSocket(writeHeaders: false);
            socket.destroy();
            return;
          }
          request.response.headers.set('content-type', 'text/event-stream');
          request.response.bufferOutput = false;
          request.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'})}\n\n');
          await request.response.flush();
          // keep the stream open
          await Future<void>.delayed(const Duration(seconds: 10));
          await request.response.close();
        } else {
          // DELETE: the client ends its session
          request.response.statusCode = 204;
          await request.response.close();
        }
      });

      final client = Client(name: 'c', version: '1');
      final pushed = Completer<void>();
      client.onToolsListChanged(() {
        if (!pushed.isCompleted) pushed.complete();
      });
      await client.connect(
        await StreamableHttpClientTransport.create(baseUrl: 'http://127.0.0.1:${server.port}/mcp'),
        era: ProtocolEra.legacy,
      );
      addTearDown(client.disconnect);

      await pushed.future.timeout(const Duration(seconds: 15),
          onTimeout: () => fail('the push stream was not opened again (attempts: ${getAttempts.length})'));
      expect(getAttempts.length, greaterThanOrEqualTo(2));
    });
  });
}
