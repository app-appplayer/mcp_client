/// Lifecycle on the client side (specification, basic/lifecycle and
/// utilities): a server version this client does not support ends the
/// connection; request timeouts are per request, cancel the request on
/// expiry, restart on progress, and never exceed the maximum; clientInfo
/// carries every Implementation field the client sets.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

Map<String, dynamic> _initResult(String version) => {
      'jsonrpc': '2.0',
      'result': {
        'protocolVersion': version,
        'serverInfo': {'name': 's', 'version': '1'},
        'capabilities': {'tools': <String, dynamic>{}},
      },
    };

void main() {
  test('a server version this client does not support ends the connection', () async {
    final transport = MockTransport()..queueResponse(_initResult('1999-01-01'));
    final client = Client(name: 'c', version: '1');
    await expectLater(client.connect(transport, era: ProtocolEra.legacy), throwsA(isA<McpError>()));
    expect(client.isConnected, isFalse);
  });

  test('clientInfo carries title, websiteUrl and icons when set', () async {
    final transport = MockTransport()..queueResponse(_initResult('2025-11-25'));
    final client = Client(
      name: 'c',
      version: '1',
      title: 'Client',
      websiteUrl: 'https://example.com',
      icons: [McpIcon(src: 'https://example.com/i.png')],
    );
    await client.connect(transport, era: ProtocolEra.legacy);
    final init = transport.sentMessages.firstWhere((m) => m['method'] == 'initialize');
    expect(init['params']['clientInfo'], {
      'name': 'c',
      'version': '1',
      'title': 'Client',
      'websiteUrl': 'https://example.com',
      'icons': [
        {'src': 'https://example.com/i.png'}
      ],
    });
    client.disconnect();
  });

  group('timeouts', () {
    late MockTransport transport;
    late Client client;

    setUp(() async {
      transport = MockTransport()..queueResponse(_initResult('2025-11-25'));
      client = Client(
        name: 'c',
        version: '1',
        requestTimeout: const Duration(seconds: 5),
        maxRequestTimeout: const Duration(milliseconds: 300),
      );
      await client.connect(transport, era: ProtocolEra.legacy);
    });

    tearDown(() => client.disconnect());

    test('a per-request timeout expires and cancels the request', () async {
      await expectLater(
        client.callTool('slow', const {}, options: const RequestOptions(timeout: Duration(milliseconds: 40))),
        throwsA(isA<McpError>()),
      );
      final call = transport.sentMessages.lastWhere((m) => m['method'] == 'tools/call');
      final cancelled = transport.sentMessages.lastWhere((m) => m['method'] == 'notifications/cancelled');
      expect(cancelled['params']['requestId'], call['id']);
    });

    test('progress reaches the callback and restarts the wait', () async {
      final seen = <ProgressNotificationParams>[];
      final future = client.callTool(
        'long',
        const {},
        options: RequestOptions(timeout: const Duration(milliseconds: 60), onProgress: seen.add),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final call = transport.sentMessages.lastWhere((m) => m['method'] == 'tools/call');
      final token = call['params']['_meta']['progressToken'];
      expect(token, isNotNull);

      // Progress every 40ms keeps a 60ms wait alive past 60ms.
      for (var i = 1; i <= 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'method': 'notifications/progress',
          'params': {'progressToken': token, 'progress': i, 'total': 4},
        });
      }
      transport.simulateMessage({
        'jsonrpc': '2.0',
        'id': call['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'done'}
          ],
        },
      });
      final result = await future;
      expect((result.content.single as TextContent).text, 'done');
      expect(seen.map((p) => p.progress), [1, 2, 3]);
    });

    test('progress never extends past the maximum', () async {
      final future = client.callTool(
        'endless',
        const {},
        options: RequestOptions(timeout: const Duration(milliseconds: 60), onProgress: (_) {}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final call = transport.sentMessages.lastWhere((m) => m['method'] == 'tools/call');
      final token = call['params']['_meta']['progressToken'];
      final ticker = Timer.periodic(const Duration(milliseconds: 30), (t) {
        transport.simulateMessage({
          'jsonrpc': '2.0',
          'method': 'notifications/progress',
          'params': {'progressToken': token, 'progress': t.tick},
        });
      });
      final started = DateTime.now();
      await expectLater(future, throwsA(isA<McpError>()));
      ticker.cancel();
      expect(DateTime.now().difference(started), lessThan(const Duration(milliseconds: 600)));
    });
  });
}
