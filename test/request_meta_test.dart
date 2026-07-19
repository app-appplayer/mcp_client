/// 2026-07-28 stateless core (SEP-2577) — reverse-DNS `_meta` key helpers.
///
/// Mirror of the server package's `request_meta_test.dart`: the two packages
/// use the identical key constants and value shapes so a stateless request
/// written by the client is read by the server (and vice-versa for serverInfo).
library;

import 'package:test/test.dart';
import 'package:mcp_client/mcp_client.dart';

void main() {
  group('McpRequestMeta keys', () {
    test('reverse-DNS key constants match the draft schema', () {
      expect(McpRequestMeta.keyProtocolVersion,
          equals('io.modelcontextprotocol/protocolVersion'));
      expect(McpRequestMeta.keyClientInfo,
          equals('io.modelcontextprotocol/clientInfo'));
      expect(McpRequestMeta.keyClientCapabilities,
          equals('io.modelcontextprotocol/clientCapabilities'));
      expect(McpRequestMeta.keyLogLevel,
          equals('io.modelcontextprotocol/logLevel'));
      expect(McpRequestMeta.keyServerInfo,
          equals('io.modelcontextprotocol/serverInfo'));
    });
  });

  group('McpRequestMeta.build', () {
    test('emits required + optional keys, omitting absent optionals', () {
      final full = McpRequestMeta.build(
        protocolVersion: McpProtocol.v2026_07_28,
        clientCapabilities: {'sampling': <String, dynamic>{}},
        clientInfo: {'name': 'c', 'version': '1.0.0'},
        logLevel: 'warning',
      );
      expect(full[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      expect(full[McpRequestMeta.keyClientInfo],
          {'name': 'c', 'version': '1.0.0'});
      expect(full[McpRequestMeta.keyLogLevel], 'warning');

      final minimal = McpRequestMeta.build(
        protocolVersion: '2026-07-28',
        clientCapabilities: <String, dynamic>{},
      );
      expect(minimal.containsKey(McpRequestMeta.keyClientInfo), isFalse);
      expect(minimal.containsKey(McpRequestMeta.keyLogLevel), isFalse);
      expect(minimal[McpRequestMeta.keyClientCapabilities],
          <String, dynamic>{});
    });

    test('extra merges first; reserved keys win; inputs untouched', () {
      final extra = {'progressToken': 3, 'com.example/x': 1};
      final meta = McpRequestMeta.build(
        protocolVersion: '2026-07-28',
        clientCapabilities: <String, dynamic>{},
        extra: extra,
      );
      expect(meta['progressToken'], 3);
      expect(meta['com.example/x'], 1);
      expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      expect(extra.containsKey(McpRequestMeta.keyProtocolVersion), isFalse);
    });
  });

  group('McpRequestMeta read helpers', () {
    test('reads typed fields and tolerates bad input', () {
      final meta = {
        McpRequestMeta.keyProtocolVersion: '2026-07-28',
        McpRequestMeta.keyClientCapabilities: {'roots': <String, dynamic>{}},
        McpRequestMeta.keyLogLevel: 'error',
        'other': 'x',
      };
      expect(McpRequestMeta.readProtocolVersion(meta), '2026-07-28');
      expect(McpRequestMeta.readClientCapabilities(meta),
          {'roots': <String, dynamic>{}});
      expect(McpRequestMeta.readLogLevel(meta), 'error');
      expect(McpRequestMeta.readProtocolVersion(null), isNull);
      expect(McpRequestMeta.readClientCapabilities({}), isNull);
    });

    test('serverInfo result key round-trips', () {
      final resultMeta =
          McpRequestMeta.buildResult(serverInfo: {'name': 's', 'version': '1'});
      expect(McpRequestMeta.readServerInfo(resultMeta),
          {'name': 's', 'version': '1'});
    });

    test('readClientInfo reads a typed map and tolerates absence/bad shape',
        () {
      final meta = {
        McpRequestMeta.keyClientInfo: {'name': 'c', 'version': '1.0.0'},
      };
      expect(McpRequestMeta.readClientInfo(meta),
          {'name': 'c', 'version': '1.0.0'});
      expect(McpRequestMeta.readClientInfo(const {}), isNull);
      expect(McpRequestMeta.readClientInfo(null), isNull);
    });

    test('buildResult merges extra first; reserved key wins', () {
      final extra = {'com.example/x': 1};
      final resultMeta = McpRequestMeta.buildResult(
        serverInfo: {'name': 's', 'version': '1'},
        extra: extra,
      );
      expect(resultMeta['com.example/x'], 1);
      expect(resultMeta[McpRequestMeta.keyServerInfo],
          {'name': 's', 'version': '1'});
    });

    test('readSubscriptionId reads the reverse-DNS notification key', () {
      final meta = {McpRequestMeta.keySubscriptionId: 42};
      expect(McpRequestMeta.readSubscriptionId(meta), 42);
      expect(McpRequestMeta.readSubscriptionId(const {}), isNull);
    });
  });
}
