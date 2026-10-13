/// What the client accepts from a server (basic, utilities/cancellation):
/// the JSON-RPC envelope as MCP narrows it, batches (2025-03-26: receivers
/// must accept them), and cancellation in both directions.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

Future<void> _settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late MockTransport transport;
  late Client client;

  setUp(() async {
    transport = MockTransport()
      ..queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'protocolVersion': '2025-03-26',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {'tools': <String, dynamic>{}},
        },
      });
    client = Client(
      name: 'c',
      version: '1',
      capabilities: const ClientCapabilities(roots: true, sampling: true),
    );
    await client.connect(transport, era: ProtocolEra.legacy);
  });

  tearDown(() => client.disconnect());

  List<Map<String, dynamic>> sentAfter(int n) => transport.sentMessages.skip(n).toList();

  test('a malformed request from the server is Invalid Request', () async {
    final n = transport.sentMessages.length;
    transport.simulateMessage({'jsonrpc': '2.0', 'id': 1.5, 'method': 'ping'});
    transport.simulateMessage({'jsonrpc': '2.0', 'id': 3, 'method': 'ping', 'params': [1]});
    await _settle();
    final out = sentAfter(n);
    expect(out.map((m) => m['error']['code']), [-32600, -32600]);
    expect(out.map((m) => m['id']), [null, 3]);
  });

  test('a malformed response is reported, not answered', () async {
    final errors = <McpError>[];
    final sub = client.onError.listen(errors.add);
    final n = transport.sentMessages.length;
    transport.simulateMessage({'jsonrpc': '2.0', 'id': 1, 'result': {}, 'error': {'code': 1, 'message': 'x'}});
    await _settle();
    expect(sentAfter(n), isEmpty);
    expect(errors.single.message, contains('exactly one of'));
    await sub.cancel();
  });

  test('a batch of requests is answered with one array', () async {
    final n = transport.sentMessages.length;
    transport.simulateMessage([
      {'jsonrpc': '2.0', 'id': 'a', 'method': 'ping'},
      {'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'},
      {'jsonrpc': '2.0', 'id': 'b', 'method': 'roots/list'},
      {'jsonrpc': '2.0', 'id': 'c', 'method': 'no/such'},
    ]);
    await _settle();
    final out = transport.sentMessages.skip(n).toList();
    // MockTransport records list messages as-is when they are not maps.
    expect(out, isEmpty, reason: 'a batch answer is a list, recorded separately');
    final batch = transport.sentBatches.single;
    expect(batch.map((m) => m['id']), ['a', 'b', 'c']);
    expect(batch[0]['result'], isA<Map>());
    expect(batch[1]['result']['roots'], isA<List>());
    expect(batch[2]['error']['code'], -32601);
  });

  test('a server request cancelled while handled gets no response', () async {
    final gate = Completer<void>();
    client.onSamplingRequest((_) async {
      await gate.future;
      return CreateMessageResult(
        role: Role.assistant,
        content: [TextContent(text: 'late')],
        model: 'm',
      );
    });
    final n = transport.sentMessages.length;
    transport.simulateMessage({
      'jsonrpc': '2.0',
      'id': 'srv-1',
      'method': 'sampling/createMessage',
      'params': {'messages': [], 'maxTokens': 1},
    });
    await _settle();
    transport.simulateMessage({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': 'srv-1'},
    });
    await _settle();
    gate.complete();
    await _settle();
    expect(sentAfter(n).where((m) => m['id'] == 'srv-1'), isEmpty);
  });

  test('a caller can cancel its own request', () async {
    final cancel = Completer<Object?>();
    final call = client.callTool('slow', const {}, options: RequestOptions(cancel: cancel.future));
    await _settle();
    final sent = transport.sentMessages.lastWhere((m) => m['method'] == 'tools/call');
    cancel.complete('user stopped it');
    await expectLater(call, throwsA(isA<McpError>()));
    final note = transport.sentMessages.lastWhere((m) => m['method'] == 'notifications/cancelled');
    expect(note['params'], {'requestId': sent['id'], 'reason': 'user stopped it'});

    // A response arriving afterwards is ignored.
    transport.simulateMessage({'jsonrpc': '2.0', 'id': sent['id'], 'result': {'content': []}});
    await _settle();
  });
}
