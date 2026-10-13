/// Clients should validate structured tool results against the tool's
/// outputSchema (specification, server/tools: Output Schema).
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
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {'tools': <String, dynamic>{}},
        },
      })
      ..queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'tools': [
            {
              'name': 'weather',
              'inputSchema': {'type': 'object'},
              'outputSchema': {
                'type': 'object',
                'properties': {'temp': {'type': 'number'}},
                'required': ['temp'],
              },
            },
          ],
        },
      });
    client = Client(name: 'c', version: '1');
    await client.connect(transport, era: ProtocolEra.legacy);
    await client.listTools();
  });

  tearDown(() => client.disconnect());

  void answer(Map<String, dynamic> result) => transport.queueResponse({'jsonrpc': '2.0', 'result': result});

  test('conforming structuredContent passes', () async {
    answer({'content': [], 'structuredContent': {'temp': 20.5}});
    final r = await client.callTool('weather', const {});
    expect(r.toJson()['structuredContent'], {'temp': 20.5});
  });

  test('nonconforming structuredContent fails the call', () async {
    answer({'content': [], 'structuredContent': {'temp': 'hot'}});
    await expectLater(client.callTool('weather', const {}),
        throwsA(isA<McpError>().having((e) => e.message, 'message', contains('/temp'))));
  });

  test('missing structuredContent fails the call', () async {
    answer({'content': []});
    await expectLater(client.callTool('weather', const {}), throwsA(isA<McpError>()));
  });

  test('error results are not checked', () async {
    answer({'content': [{'type': 'text', 'text': 'down'}], 'isError': true});
    expect((await client.callTool('weather', const {})).isError, isTrue);
  });

  test('validation can be turned off', () async {
    client.validateToolOutput = false;
    answer({'content': [], 'structuredContent': {'temp': 'hot'}});
    await client.callTool('weather', const {});
  });
}
