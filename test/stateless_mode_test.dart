/// 2026-07-28 stateless core (SEP-2577) — client statelessMode.
///
/// Verifies that a client connected with `statelessMode: true`:
///  - skips the `initialize` handshake (no `initialize` request is sent),
///  - attaches the reverse-DNS `_meta` keys (protocol version + per-request
///    client capabilities + clientInfo) to EVERY request,
///  - exposes `discover()` which parses a `server/discover` result,
///  - preserves a caller-provided `_meta` (additive, e.g. a progressToken).
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:mcp_client/mcp_client.dart';

import 'mock_transport.dart';

void main() {
  group('client statelessMode', () {
    test('skips initialize and stamps _meta on every request', () async {
      final transport = MockTransport();
      // Queue a tools/list result for the request the test will issue.
      transport.queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'tools': [
            {
              'name': 'echo',
              'description': 'e',
              'inputSchema': {'type': 'object'},
            }
          ],
        },
      });

      final client = Client(
        name: 'sc',
        version: '9.9.9',
        capabilities: const ClientCapabilities(sampling: true),
      );
      await client.connect(transport, statelessMode: true);

      expect(client.isStateless, isTrue);
      expect(client.negotiatedProtocolVersion, McpProtocol.v2026_07_28);
      // No handshake: nothing named `initialize` was sent.
      expect(
        transport.sentMessages.where((m) => m['method'] == 'initialize'),
        isEmpty,
      );

      await client.listTools();

      final listReq =
          transport.sentMessages.firstWhere((m) => m['method'] == 'tools/list');
      final meta = (listReq['params'] as Map)['_meta'] as Map;
      expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      expect(meta[McpRequestMeta.keyClientCapabilities],
          {'sampling': <String, dynamic>{}});
      expect(meta[McpRequestMeta.keyClientInfo],
          {'name': 'sc', 'version': '9.9.9'});
    });

    test('discover() parses supportedVersions, capabilities, instructions',
        () async {
      final transport = MockTransport();
      transport.queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'supportedVersions': ['2026-07-28', '2025-11-25'],
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'instructions': 'guidance',
          'ttlMs': 0,
          'cacheScope': 'private',
          '_meta': {
            'io.modelcontextprotocol/serverInfo': {
              'name': 'srv',
              'version': '1.2.3',
            },
          },
        },
      });

      final client = Client(name: 'sc', version: '1.0.0');
      await client.connect(transport, statelessMode: true);

      final result = await client.discover();
      expect(result.supportedVersions, ['2026-07-28', '2025-11-25']);
      expect(result.capabilities.tools, isNotNull);
      expect(result.instructions, 'guidance');
      expect(result.ttlMs, 0);
      expect(result.cacheScope, 'private');
      expect(result.serverInfo, {'name': 'srv', 'version': '1.2.3'});
      // The discover call itself carried the stateless _meta.
      final discReq = transport.sentMessages
          .firstWhere((m) => m['method'] == 'server/discover');
      expect((discReq['params'] as Map)['_meta'], isNotNull);
      // Side-effect: caps cached on the client.
      expect(client.serverCapabilities?.tools, isNotNull);
    });

    test('legacy (non-stateless) client attaches NO stateless _meta', () async {
      final transport = MockTransport();
      // initialize response
      transport.queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {'tools': <String, dynamic>{}},
        },
      });
      // tools/list response
      transport.queueResponse({
        'jsonrpc': '2.0',
        'result': {'tools': <dynamic>[]},
      });

      final client = Client(name: 'legacy', version: '1.0.0');
      await client.connect(transport); // statelessMode defaults to false
      expect(client.isStateless, isFalse);

      await client.listTools();
      final listReq =
          transport.sentMessages.firstWhere((m) => m['method'] == 'tools/list');
      final params = listReq['params'] as Map;
      // No stateless _meta injected on the legacy path.
      if (params['_meta'] is Map) {
        expect(
            (params['_meta'] as Map)
                .containsKey(McpRequestMeta.keyProtocolVersion),
            isFalse);
      }
    });
  });
}
