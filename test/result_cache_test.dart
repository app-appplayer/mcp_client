/// 2026-07-28 caching (server/utilities/caching): fresh results are reused
/// for the same method and parameters only, list_changed / updated
/// notifications invalidate, multi-round-trip retries and non-positive TTLs
/// are never cached.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

void main() {
  late MockTransport transport;
  late Client client;

  setUp(() async {
    transport = MockTransport()
      ..queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'supportedVersions': ['2026-07-28'],
          'capabilities': {'tools': <String, dynamic>{}, 'resources': <String, dynamic>{}},
          'serverInfo': {'name': 's', 'version': '1'},
          'resultType': 'complete',
        },
      });
    client = Client(name: 'c', version: '1')..cacheResults = true;
    await client.connect(transport);
  });

  tearDown(() => client.disconnect());

  void answer(Map<String, dynamic> result) => transport.queueResponse({'jsonrpc': '2.0', 'result': result});
  int sent(String method) => transport.sentMessages.where((m) => m['method'] == method).length;
  Map<String, dynamic> tools(int ttl) =>
      {'tools': [], 'ttlMs': ttl, 'cacheScope': 'public', 'resultType': 'complete'};

  test('a fresh result is reused', () async {
    answer(tools(60000));
    await client.listToolsPage();
    await client.listToolsPage();
    expect(sent('tools/list'), 1);
  });

  test('different parameters are a different entry', () async {
    answer(tools(60000));
    answer(tools(60000));
    await client.listToolsPage();
    await client.listToolsPage(cursor: 'p2');
    expect(sent('tools/list'), 2);
  });

  test('ttlMs 0, negative or absent is never reused', () async {
    for (final r in [tools(0), tools(-5), {'tools': [], 'resultType': 'complete'}]) {
      answer(r);
      answer(r);
      final before = sent('tools/list');
      await client.listToolsPage();
      await client.listToolsPage();
      expect(sent('tools/list') - before, 2, reason: '$r');
    }
  });

  test('list_changed invalidates', () async {
    answer(tools(60000));
    answer(tools(60000));
    await client.listToolsPage();
    transport.simulateMessage({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await client.listToolsPage();
    expect(sent('tools/list'), 2);
  });

  test('tools/call is never cached', () async {
    answer({'content': [], 'ttlMs': 60000, 'resultType': 'complete'});
    answer({'content': [], 'resultType': 'complete'});
    await client.callTool('t', const {});
    await client.callTool('t', const {});
    expect(sent('tools/call'), 2);
  });

  test('off by default', () async {
    client.cacheResults = false;
    answer(tools(60000));
    answer(tools(60000));
    await client.listToolsPage();
    await client.listToolsPage();
    expect(sent('tools/list'), 2);
  });
}
