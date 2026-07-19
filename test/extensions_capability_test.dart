/// Extensions framework (MCP 2026-07-28) — Client/ServerCapabilities
/// `extensions` map round-trip + `hasExtension`. Additive; absent by default.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('Extensions framework — capabilities', () {
    test('ClientCapabilities extensions round-trip', () {
      // Extensions in isolation (other fields default) — a full round-trip
      // with sampling:true would trip a pre-existing latent parse issue in
      // ClientCapabilities.fromJson (empty `{}` map cast), unrelated to
      // extensions; flagged separately.
      const caps = ClientCapabilities(
        extensions: {
          'io.modelcontextprotocol/tasks': {},
          'io.example/thing': {'setting': true},
        },
      );
      final json = caps.toJson();
      expect(json['extensions'], {
        'io.modelcontextprotocol/tasks': {},
        'io.example/thing': {'setting': true},
      });
      final back = ClientCapabilities.fromJson(json);
      expect(back.hasExtension('io.modelcontextprotocol/tasks'), isTrue);
      expect(back.extensions!['io.example/thing'], {'setting': true});
    });

    test('ServerCapabilities reads advertised extensions', () {
      final caps = ServerCapabilities.fromJson({
        'tools': {'listChanged': false},
        'extensions': {
          'io.modelcontextprotocol/tasks': {'maxConcurrent': 4},
        },
      });
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isTrue);
      expect(caps.extensions!['io.modelcontextprotocol/tasks'],
          {'maxConcurrent': 4});
      expect(caps.hasExtension('io.absent/x'), isFalse);
    });

    test('absent extensions omits the key (backward compatible)', () {
      const caps = ClientCapabilities(sampling: true);
      expect(caps.toJson().containsKey('extensions'), isFalse);
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isFalse);
      final srv = ServerCapabilities.fromJson({'tools': {'listChanged': false}});
      expect(srv.hasExtension('io.modelcontextprotocol/tasks'), isFalse);
    });
  });
}
