import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// `description` is OPTIONAL on tools, resources and resource templates per
/// the MCP spec (schema.ts `description?: string`). A spec-conforming server
/// that omits it must parse — the old non-null cast made `tools/list` against
/// such a server throw
/// `type 'Null' is not a subtype of type 'String' in type cast`
/// (surfaced live: the marketplace Verify sample server omits tool
/// descriptions).
void main() {
  group('optional description parsing (MCP spec conformance)', () {
    test('Tool.fromJson tolerates a missing description', () {
      final tool = Tool.fromJson(const {
        'name': 'verify.ping',
        'inputSchema': {'type': 'object'},
      });
      expect(tool.name, 'verify.ping');
      expect(tool.description, '');
    });

    test('Resource.fromJson tolerates a missing description', () {
      final resource = Resource.fromJson(const {
        'uri': 'ui://app',
        'name': 'app',
      });
      expect(resource.uri, 'ui://app');
      expect(resource.description, '');
    });

    test('ResourceTemplate.fromJson tolerates a missing description', () {
      final template = ResourceTemplate.fromJson(const {
        'uriTemplate': 'file:///{path}',
        'name': 'files',
      });
      expect(template.uriTemplate, 'file:///{path}');
      expect(template.description, '');
    });

    test('present descriptions still round-trip', () {
      final tool = Tool.fromJson(const {
        'name': 'verify.ping',
        'description': 'Ping the verifier',
        'inputSchema': {'type': 'object'},
      });
      expect(tool.description, 'Ping the verifier');
    });
  });
}
