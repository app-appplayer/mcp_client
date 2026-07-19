import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

/// Wire-behavior + round-trip coverage for the 2025-11-25 Part-A items
/// (PROTOCOL-REVISION-PLAN.md): A1 (error-code finding), A3 (sampling
/// tools/toolChoice), A4 (typed elicitation), A9 (Implementation.description),
/// A10 (JSON Schema 2020-12 default dialect).
void main() {
  // --------------------------------------------------------------------------
  // A1 — error code -32001 finding (documented, unchanged)
  // --------------------------------------------------------------------------
  group('A1 error-code semantics (unchanged, ecosystem-consistent)', () {
    test('client resourceNotFound == -32001 matches makemind server', () {
      // The transport injects `-32001` as an internal "authentication
      // required" sentinel, NOT as resource-not-found. The client's
      // resource-not-found constant is -32001 to stay consistent with the
      // makemind server package (which uses -32001 for resourceNotFound and
      // -32002 for promptNotFound). Renaming to -32002 would break both.
      expect(McpProtocol.errorResourceNotFound, equals(-32001));
      expect(McpProtocol.errorResourceAccessDenied, equals(-32002));
    });
  });

  // --------------------------------------------------------------------------
  // A3 — Sampling tools / toolChoice
  // --------------------------------------------------------------------------
  group('A3 sampling tools/toolChoice', () {
    test('CreateMessageRequest tools + toolChoice round-trip', () {
      final req = CreateMessageRequest(
        messages: const [
          Message(role: 'user', content: TextContent(text: 'weather?')),
        ],
        maxTokens: 100,
        tools: const [
          Tool(
            name: 'get_weather',
            description: 'Look up weather',
            inputSchema: {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
            },
          ),
        ],
        toolChoice: SamplingToolChoice.tool('get_weather'),
      );

      final json = req.toJson();
      expect(json['tools'], isA<List>());
      expect((json['tools'] as List).single['name'], equals('get_weather'));
      expect(json['toolChoice'], equals({'type': 'tool', 'name': 'get_weather'}));

      final parsed = CreateMessageRequest.fromJson(json);
      expect(parsed.tools, isNotNull);
      expect(parsed.tools!.single, isA<Tool>());
      expect(parsed.tools!.single.name, equals('get_weather'));
      expect(parsed.toolChoice, equals({'type': 'tool', 'name': 'get_weather'}));
    });

    test('toolChoice mode-string form round-trips losslessly', () {
      final req = CreateMessageRequest(
        messages: const [
          Message(role: 'user', content: TextContent(text: 'hi')),
        ],
        toolChoice: SamplingToolChoice.auto,
      );
      final parsed = CreateMessageRequest.fromJson(req.toJson());
      expect(parsed.toolChoice, equals('auto'));
    });

    test('request without tools omits the keys (backward compatible)', () {
      const req = CreateMessageRequest(
        messages: [Message(role: 'user', content: TextContent(text: 'hi'))],
      );
      final json = req.toJson();
      expect(json.containsKey('tools'), isFalse);
      expect(json.containsKey('toolChoice'), isFalse);
    });

    test('CreateMessageResult carries toolCalls', () {
      final result = CreateMessageResult(
        model: 'claude',
        role: 'assistant',
        stopReason: 'tool_use',
        content: const TextContent(text: ''),
        toolCalls: const [
          {'name': 'get_weather', 'arguments': {'city': 'Seoul'}},
        ],
      );
      final json = result.toJson();
      expect(json['toolCalls'], isA<List>());

      final parsed = CreateMessageResult.fromJson(json);
      expect(parsed.hasToolCalls, isTrue);
      expect(parsed.toolCalls!.single['name'], equals('get_weather'));
    });

    test('plain completion result has no toolCalls', () {
      final json = {
        'model': 'claude',
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'hello'},
      };
      final parsed = CreateMessageResult.fromJson(json);
      expect(parsed.hasToolCalls, isFalse);
      expect(parsed.toJson().containsKey('toolCalls'), isFalse);
    });

    test('typed sampling handler receives tools over the wire', () async {
      final config = McpClient.productionConfig(
        name: 'A3 client',
        version: '1.0.0',
        capabilities: const ClientCapabilities(sampling: true),
      );
      final client = McpClient.createClient(config);
      final transport = MockTransport();

      transport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 'srv', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      CreateMessageRequest? received;
      client.onSamplingRequest((req) async {
        received = req;
        return CreateMessageResult(
          model: 'claude',
          role: 'assistant',
          stopReason: 'tool_use',
          content: const TextContent(text: ''),
          toolCalls: const [
            {'name': 'get_weather', 'arguments': {'city': 'Seoul'}},
          ],
        );
      });

      await client.connect(transport);

      transport.simulateMessage({
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'sampling/createMessage',
        'params': {
          'messages': [
            {'role': 'user', 'content': {'type': 'text', 'text': 'weather?'}},
          ],
          'maxTokens': 100,
          'tools': [
            {
              'name': 'get_weather',
              'description': 'Look up weather',
              'inputSchema': {'type': 'object'},
            },
          ],
          'toolChoice': 'auto',
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, isNotNull);
      expect(received!.tools!.single.name, equals('get_weather'));
      expect(received!.toolChoice, equals('auto'));

      final response = transport.sentMessages.firstWhere(
        (m) => m['id'] == 42,
      );
      expect(response['result']['toolCalls'], isA<List>());
      expect(
        (response['result']['toolCalls'] as List).single['name'],
        equals('get_weather'),
      );

      client.disconnect();
    });
  });

  // --------------------------------------------------------------------------
  // A4 — Elicitation typed layer
  // --------------------------------------------------------------------------
  group('A4 elicitation typed layer', () {
    test('EnumSchema titled vs untitled', () {
      final titled = EnumSchema.fromJson({
        'enum': ['r', 'g', 'b'],
        'enumNames': ['Red', 'Green', 'Blue'],
      });
      expect(titled.isTitled, isTrue);
      expect(titled.titleFor('g'), equals('Green'));
      expect(titled.toJson(), equals({
        'enum': ['r', 'g', 'b'],
        'enumNames': ['Red', 'Green', 'Blue'],
      }));

      final untitled = EnumSchema.fromJson({
        'enum': ['a', 'b'],
      });
      expect(untitled.isTitled, isFalse);
      expect(untitled.titleFor('a'), equals('a'));
      expect(untitled.toJson().containsKey('enumNames'), isFalse);
    });

    test('single-select enum field with default (SEP-1034)', () {
      final field = ElicitationFieldSchema.fromJson({
        'type': 'string',
        'enum': ['low', 'high'],
        'enumNames': ['Low', 'High'],
        'default': 'low',
        'title': 'Priority',
      });
      expect(field, isA<EnumElicitationField>());
      final e = field as EnumElicitationField;
      expect(e.enumSchema.values, equals(['low', 'high']));
      expect(e.defaultValue, equals('low'));
      expect(e.title, equals('Priority'));
      // Round-trip preserves enum, names, default.
      final rt = e.toJson();
      expect(rt['enum'], equals(['low', 'high']));
      expect(rt['enumNames'], equals(['Low', 'High']));
      expect(rt['default'], equals('low'));
    });

    test('multi-select enum field (SEP-1330) with defaults', () {
      final field = ElicitationFieldSchema.fromJson({
        'type': 'array',
        'items': {
          'type': 'string',
          'enum': ['a', 'b', 'c'],
          'enumNames': ['A', 'B', 'C'],
        },
        'uniqueItems': true,
        'default': ['a', 'c'],
      });
      expect(field, isA<MultiSelectEnumElicitationField>());
      final m = field as MultiSelectEnumElicitationField;
      expect(m.enumSchema.values, equals(['a', 'b', 'c']));
      expect(m.enumSchema.titleFor('b'), equals('B'));
      expect(m.defaultValue, equals(['a', 'c']));
      expect(m.uniqueItems, isTrue);

      final rt = m.toJson();
      expect(rt['type'], equals('array'));
      expect((rt['items'] as Map)['enum'], equals(['a', 'b', 'c']));
      expect(rt['default'], equals(['a', 'c']));
      expect(rt['uniqueItems'], isTrue);
    });

    test('primitive fields carry defaults (SEP-1034)', () {
      final s = ElicitationFieldSchema.fromJson(
          {'type': 'string', 'default': 'hi'}) as StringElicitationField;
      expect(s.defaultValue, equals('hi'));

      final n = ElicitationFieldSchema.fromJson(
              {'type': 'integer', 'default': 5, 'minimum': 0})
          as NumberElicitationField;
      expect(n.integer, isTrue);
      expect(n.defaultValue, equals(5));
      expect(n.minimum, equals(0));

      final b = ElicitationFieldSchema.fromJson(
          {'type': 'boolean', 'default': true}) as BooleanElicitationField;
      expect(b.defaultValue, isTrue);
    });

    test('form-mode request parses fields and required', () {
      final req = ElicitationRequest.fromJson({
        'message': 'Tell us about yourself',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'default': 'Anon'},
            'color': {
              'type': 'string',
              'enum': ['r', 'g'],
            },
          },
          'required': ['name'],
        },
      });
      expect(req.mode, equals(ElicitationMode.form));
      expect(req.isUrlMode, isFalse);
      expect(req.fields.keys, containsAll(['name', 'color']));
      expect(req.fields['name'], isA<StringElicitationField>());
      expect(req.fields['color'], isA<EnumElicitationField>());
      expect(req.requiredFields, equals(['name']));
      // Lossless round-trip of raw params.
      expect(req.toJson()['message'], equals('Tell us about yourself'));
    });

    test('url-mode request (SEP-1036)', () {
      final req = ElicitationRequest.fromJson({
        'message': 'Complete auth in browser',
        'mode': 'url',
        'url': 'https://example.com/consent',
      });
      expect(req.mode, equals(ElicitationMode.url));
      expect(req.isUrlMode, isTrue);
      expect(req.url, equals('https://example.com/consent'));
      expect(req.toJson()['mode'], equals('url'));
    });

    test('ElicitationResponse serialization', () {
      expect(
        const ElicitationResponse.accept({'name': 'x'}).toJson(),
        equals({'action': 'accept', 'content': {'name': 'x'}}),
      );
      expect(const ElicitationResponse.decline().toJson(),
          equals({'action': 'decline'}));
      expect(const ElicitationResponse.cancel().toJson(),
          equals({'action': 'cancel'}));
    });

    test('typed elicitation handler dispatches over the wire', () async {
      final config = McpClient.productionConfig(
        name: 'A4 client',
        version: '1.0.0',
        capabilities: const ClientCapabilities(elicitation: true),
      );
      final client = McpClient.createClient(config);
      final transport = MockTransport();

      transport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 'srv', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      ElicitationRequest? received;
      client.onElicitationRequestTyped((req) async {
        received = req;
        return const ElicitationResponse.accept({'color': 'g'});
      });

      await client.connect(transport);

      transport.simulateMessage({
        'jsonrpc': '2.0',
        'id': 77,
        'method': 'elicitation/create',
        'params': {
          'message': 'Pick a color',
          'requestedSchema': {
            'type': 'object',
            'properties': {
              'color': {
                'type': 'string',
                'enum': ['r', 'g'],
                'enumNames': ['Red', 'Green'],
              },
            },
          },
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, isNotNull);
      final colorField = received!.fields['color'] as EnumElicitationField;
      expect(colorField.enumSchema.titleFor('g'), equals('Green'));

      final response = transport.sentMessages.firstWhere((m) => m['id'] == 77);
      expect(response['result'], equals({
        'action': 'accept',
        'content': {'color': 'g'},
      }));

      // Raw-map path still works after typed registration is available.
      client.onElicitationRequest((params) async => {'action': 'cancel'});
      client.disconnect();
    });
  });

  // --------------------------------------------------------------------------
  // A9 — Implementation.description
  // --------------------------------------------------------------------------
  group('A9 Implementation.description', () {
    test('ClientInfo/ServerInfo description round-trip', () {
      const ci = ClientInfo(
        name: 'c',
        version: '1.0.0',
        description: 'A test client',
      );
      expect(ci.toJson()['description'], equals('A test client'));
      expect(
        ClientInfo.fromJson(ci.toJson()).description,
        equals('A test client'),
      );

      const si = ServerInfo(
        name: 's',
        version: '1.0.0',
        description: 'A test server',
      );
      expect(si.toJson()['description'], equals('A test server'));
      expect(
        ServerInfo.fromJson(si.toJson()).description,
        equals('A test server'),
      );
    });

    test('initialize emits clientInfo.description when set', () async {
      final config = McpClient.productionConfig(
        name: 'described client',
        version: '2.0.0',
        description: 'Does useful things',
      );
      final client = McpClient.createClient(config);
      final transport = MockTransport();

      transport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 'srv', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      await client.connect(transport);

      final init = transport.sentMessages.firstWhere(
        (m) => m['method'] == 'initialize',
      );
      final clientInfo = init['params']['clientInfo'] as Map;
      expect(clientInfo['description'], equals('Does useful things'));
      client.disconnect();
    });

    test('initialize omits description when unset (backward compatible)',
        () async {
      final config = McpClient.simpleConfig(name: 'plain', version: '1.0.0');
      final client = McpClient.createClient(config);
      final transport = MockTransport();

      transport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 'srv', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      await client.connect(transport);

      final init = transport.sentMessages.firstWhere(
        (m) => m['method'] == 'initialize',
      );
      final clientInfo = init['params']['clientInfo'] as Map;
      expect(clientInfo.containsKey('description'), isFalse);
      client.disconnect();
    });
  });

  // --------------------------------------------------------------------------
  // A10 — JSON Schema 2020-12 default dialect (SEP-1613)
  // --------------------------------------------------------------------------
  group('A10 JSON Schema 2020-12 default dialect', () {
    test('dialect constant + version-gated default', () {
      expect(
        McpProtocol.jsonSchemaDialect2020_12,
        equals('https://json-schema.org/draft/2020-12/schema'),
      );
      expect(
        McpProtocol.defaultSchemaDialect(McpProtocol.v2025_11_25),
        equals(McpProtocol.jsonSchemaDialect2020_12),
      );
      // Older revisions leave the dialect unspecified.
      expect(McpProtocol.defaultSchemaDialect(McpProtocol.v2025_06_18), isNull);
      expect(McpProtocol.defaultSchemaDialect(McpProtocol.v2024_11_05), isNull);
    });

    test('stamps 2020-12 for 2025-11-25 when \$schema absent, non-mutating',
        () {
      final schema = {
        'type': 'object',
        'properties': {'x': {'type': 'string'}},
      };
      final stamped =
          McpProtocol.schemaWithDefaultDialect(schema, McpProtocol.v2025_11_25);
      expect(stamped[r'$schema'],
          equals('https://json-schema.org/draft/2020-12/schema'));
      // Original untouched (non-mutating).
      expect(schema.containsKey(r'$schema'), isFalse);
    });

    test('leaves free-form schema with own \$schema untouched', () {
      final schema = {
        r'$schema': 'https://json-schema.org/draft/2019-09/schema',
        'type': 'object',
      };
      final result =
          McpProtocol.schemaWithDefaultDialect(schema, McpProtocol.v2025_11_25);
      expect(result[r'$schema'],
          equals('https://json-schema.org/draft/2019-09/schema'));
    });

    test('does not stamp under older negotiated revision', () {
      final schema = {'type': 'object'};
      final result =
          McpProtocol.schemaWithDefaultDialect(schema, McpProtocol.v2025_06_18);
      expect(result.containsKey(r'$schema'), isFalse);
      expect(identical(result, schema), isTrue);
    });
  });

  // --------------------------------------------------------------------------
  // Version predicates (mirror server package)
  // --------------------------------------------------------------------------
  group('version predicates', () {
    test('sampling tools / url elicitation / description gated on 2025-11-25',
        () {
      expect(McpProtocol.supportsSamplingTools(McpProtocol.v2025_11_25), isTrue);
      expect(McpProtocol.supportsSamplingTools(McpProtocol.v2025_06_18), isFalse);
      expect(
          McpProtocol.supportsUrlElicitation(McpProtocol.v2025_11_25), isTrue);
      expect(
          McpProtocol.supportsUrlElicitation(McpProtocol.v2025_06_18), isFalse);
      expect(
        McpProtocol.supportsImplementationDescription(McpProtocol.v2025_11_25),
        isTrue,
      );
      expect(
        McpProtocol.supportsImplementationDescription(McpProtocol.v2024_11_05),
        isFalse,
      );
    });
  });
}
