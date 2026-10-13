/// Keep-alive pings (basic/utilities/ping): periodic at a configurable rate,
/// an unanswered ping is a connection failure.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

void main() {
  test('pings go out and an unanswered one disconnects', () async {
    final transport = MockTransport()
      ..queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': <String, dynamic>{},
        },
      })
      ..queueResponse({'jsonrpc': '2.0', 'result': <String, dynamic>{}});
    final client = Client(name: 'c', version: '1');
    await client.connect(transport, era: ProtocolEra.legacy);
    final reasons = <DisconnectReason>[];
    final sub = client.onDisconnect.listen(reasons.add);
    client.startKeepAlive(const Duration(milliseconds: 30), timeout: const Duration(milliseconds: 40));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(transport.sentMessages.where((m) => m['method'] == 'ping').length, greaterThanOrEqualTo(2));
    expect(reasons, [DisconnectReason.pingTimeout]);
    expect(client.isConnected, isFalse);
    await sub.cancel();
  });
}
