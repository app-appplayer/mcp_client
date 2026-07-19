/// Coverage for `McpProtocol` version helpers and `ProtocolCapabilities`
/// (`lib/src/protocol/protocol.dart`) not already exercised by the
/// per-version compliance suite.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('McpProtocol.isStateless', () {
    test('true only for the 2026-07-28 revision', () {
      expect(McpProtocol.isStateless(McpProtocol.v2026_07_28), isTrue);
      expect(McpProtocol.isStateless(McpProtocol.v2025_11_25), isFalse);
      expect(McpProtocol.isStateless('bogus'), isFalse);
    });
  });

  group('McpProtocol.isVersionSupported', () {
    test('true for supported versions, false otherwise', () {
      expect(McpProtocol.isVersionSupported(McpProtocol.v2025_11_25), isTrue);
      expect(McpProtocol.isVersionSupported(McpProtocol.v2024_11_05), isTrue);
      expect(McpProtocol.isVersionSupported('1999-01-01'), isFalse);
      // Declared but not yet advertised/supported.
      expect(McpProtocol.isVersionSupported(McpProtocol.v2026_07_28), isFalse);
    });
  });

  group('McpProtocol.negotiateVersion', () {
    test('returns the first mutually supported client-preferred version', () {
      final negotiated = McpProtocol.negotiateVersion(
        [McpProtocol.v2025_11_25, McpProtocol.v2025_03_26],
        [McpProtocol.v2025_03_26, McpProtocol.v2024_11_05],
      );
      expect(negotiated, McpProtocol.v2025_03_26);
    });

    test('returns null when no mutually supported version exists', () {
      final negotiated = McpProtocol.negotiateVersion(
        [McpProtocol.v2025_11_25],
        ['9999-99-99'],
      );
      expect(negotiated, isNull);
    });

    test('skips a shared but unsupported version', () {
      final negotiated = McpProtocol.negotiateVersion(
        ['unsupported-version', McpProtocol.v2024_11_05],
        ['unsupported-version', McpProtocol.v2024_11_05],
      );
      expect(negotiated, McpProtocol.v2024_11_05);
    });
  });

  group('ProtocolCapabilities', () {
    test('toJson omits false flags and includes true ones', () {
      const caps = ProtocolCapabilities(
        experimental: true,
        tools: true,
        resources: false,
        prompts: true,
        logging: false,
      );
      final json = caps.toJson();
      expect(json['experimental'], isTrue);
      expect(json['tools'], isTrue);
      expect(json.containsKey('resources'), isFalse);
      expect(json['prompts'], isTrue);
      expect(json.containsKey('logging'), isFalse);
    });

    test('defaults enable tools/resources/prompts/logging, not experimental',
        () {
      const caps = ProtocolCapabilities();
      expect(caps.experimental, isFalse);
      expect(caps.tools, isTrue);
      expect(caps.resources, isTrue);
      expect(caps.prompts, isTrue);
      expect(caps.logging, isTrue);
    });

    test('fromJson parses explicit values', () {
      final caps = ProtocolCapabilities.fromJson({
        'experimental': true,
        'tools': false,
        'resources': false,
        'prompts': false,
        'logging': false,
      });
      expect(caps.experimental, isTrue);
      expect(caps.tools, isFalse);
      expect(caps.resources, isFalse);
      expect(caps.prompts, isFalse);
      expect(caps.logging, isFalse);
    });

    test('fromJson applies defaults for absent keys', () {
      final caps = ProtocolCapabilities.fromJson(const {});
      expect(caps.experimental, isFalse);
      expect(caps.tools, isTrue);
      expect(caps.resources, isTrue);
      expect(caps.prompts, isTrue);
      expect(caps.logging, isTrue);
    });
  });
}
