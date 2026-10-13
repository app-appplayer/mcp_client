/// The era probe's outcomes (specification, stdio backward compatibility):
/// a DiscoverResult naming 2026-07-28 is modern; a modern error naming only
/// legacy versions, any other error, or silence is legacy; the fallback is
/// not keyed to one error code. Modern results with an unknown resultType are
/// invalid, and -32022 names what the server supports.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

Map<String, dynamic> _error(int code, [Object? data]) => {
      'jsonrpc': '2.0',
      'error': {'code': code, 'message': 'x', if (data != null) 'data': data},
    };

final _initResult = {
  'jsonrpc': '2.0',
  'result': {
    'protocolVersion': '2025-11-25',
    'serverInfo': {'name': 's', 'version': '1'},
    'capabilities': {'tools': <String, dynamic>{}},
  },
};

final _discoverResult = {
  'jsonrpc': '2.0',
  'result': {
    'supportedVersions': ['2026-07-28', '2025-11-25'],
    'capabilities': {'tools': <String, dynamic>{}},
    'serverInfo': {'name': 's', 'version': '1'},
    'resultType': 'complete',
  },
};

void main() {
  Future<(Client, MockTransport)> connect(List<Map<String, dynamic>> answers,
      {Duration probe = const Duration(seconds: 2)}) async {
    final transport = MockTransport();
    answers.forEach(transport.queueResponse);
    final client = Client(name: 'c', version: '1')..eraProbeTimeout = probe;
    await client.connect(transport);
    addTearDown(client.disconnect);
    return (client, transport);
  }

  List<String?> methods(MockTransport t) => [for (final m in t.sentMessages) m['method'] as String?];

  test('a DiscoverResult naming 2026-07-28 is modern, with no initialize', () async {
    final (client, transport) = await connect([_discoverResult]);
    expect(client.era, ProtocolEra.modern);
    expect(methods(transport), ['server/discover']);
    final probe = transport.sentMessages.single;
    expect(probe['params']['_meta']['io.modelcontextprotocol/protocolVersion'], '2026-07-28');
  });

  for (final code in [-32601, -32602, -32600, -32000]) {
    test('error $code means legacy', () async {
      final (client, transport) = await connect([_error(code), _initResult]);
      expect(client.era, ProtocolEra.legacy);
      expect(methods(transport), ['server/discover', 'initialize', 'notifications/initialized']);
      expect(transport.sentMessages[1]['params']['_meta'], isNull);
    });
  }

  test('no answer within the probe timeout means legacy', () async {
    final transport = MockTransport();
    transport.onSend = (message) {
      if (message is Map && message['method'] == 'initialize') {
        transport.queueResponse(_initResult);
      }
    };
    final client = Client(name: 'c', version: '1')..eraProbeTimeout = const Duration(milliseconds: 50);
    // The probe consumes nothing: an empty queue is a silent server.
    await client.connect(transport);
    addTearDown(client.disconnect);
    expect(client.era, ProtocolEra.legacy);
  });

  test('-32022 naming only legacy versions falls back to them', () async {
    final (client, _) = await connect([
      _error(-32022, {'supported': ['2025-11-25', '2025-06-18'], 'requested': '2026-07-28'}),
      _initResult,
    ]);
    expect(client.era, ProtocolEra.legacy);
    expect(client.negotiatedProtocolVersion, '2025-11-25');
  });

  test('-32022 naming nothing in common fails the connection', () async {
    final transport = MockTransport()
      ..queueResponse(_error(-32022, {'supported': ['2099-01-01'], 'requested': '2026-07-28'}));
    final client = Client(name: 'c', version: '1');
    await expectLater(
      client.connect(transport),
      throwsA(isA<McpError>().having((e) => e.message, 'message', contains('2099-01-01'))),
    );
  });

  test('a modern result with an unknown resultType is invalid', () async {
    final (client, transport) = await connect([_discoverResult]);
    transport.queueResponse({
      'jsonrpc': '2.0',
      'result': {'tools': [], 'resultType': 'something_new'},
    });
    await expectLater(
      client.listToolsPage(),
      throwsA(isA<McpError>().having((e) => e.message, 'message', contains('unknown resultType'))),
    );
  });

  test('-32022 on a later request names the supported versions', () async {
    final (client, transport) = await connect([_discoverResult]);
    transport.queueResponse(_error(-32022, {'supported': ['2027-01-01'], 'requested': '2026-07-28'}));
    await expectLater(
      client.listToolsPage(),
      throwsA(isA<McpError>()
          .having((e) => e.code, 'code', -32022)
          .having((e) => e.message, 'message', contains('2027-01-01'))),
    );
  });

  test('in the modern era the log level rides on each request', () async {
    final (client, transport) = await connect([_discoverResult]);
    await client.setLoggingLevel(McpLogLevel.warning);
    expect(transport.sentMessages.where((m) => m['method'] == 'logging/setLevel'), isEmpty);
    transport.queueResponse({'jsonrpc': '2.0', 'result': {'tools': []}});
    await client.listToolsPage();
    final sent = transport.sentMessages.lastWhere((m) => m['method'] == 'tools/list');
    expect(sent['params']['_meta']['io.modelcontextprotocol/logLevel'], 'warning');
  });
}
