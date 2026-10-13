import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

/// Wire-behavior + round-trip coverage for the 2025-11-25 Part-A items
/// (PROTOCOL-REVISION-PLAN.md): A1 (error-code finding), A3 (sampling
/// tools/toolChoice), A4 (typed elicitation), A9 (Implementation.description),
/// A10 (JSON Schema 2020-12 default dialect).
void main() {
  // --------------------------------------------------------------------------
  // Error codes (every revision)
  // --------------------------------------------------------------------------
  group('error codes', () {
    test('resource not found is -32002; 2026-07-28 also answers -32602', () {
      expect(McpProtocol.errorResourceNotFound, -32002);
      expect(McpProtocol.isResourceNotFound(-32002, '2025-11-25'), isTrue);
      expect(McpProtocol.isResourceNotFound(-32602, '2025-11-25'), isFalse);
      expect(McpProtocol.isResourceNotFound(-32602, '2026-07-28'), isTrue);
      expect(McpProtocol.isResourceNotFound(-32002, '2026-07-28'), isTrue);
    });

    test('unknown tools and prompts are Invalid params', () {
      expect(McpProtocol.errorToolNotFound, -32602);
      expect(McpProtocol.errorPromptNotFound, -32602);
    });
  });

  // --------------------------------------------------------------------------
  // A3 — Sampling tools / toolChoice (2025-11-25)
  // --------------------------------------------------------------------------
  group('A3 sampling tools/toolChoice', () {
    test('params carry tools and toolChoice', () {
      final params = CreateMessageRequestParams(
        messages: [
          SamplingMessage(role: Role.user, content: [TextContent(text: 'weather?')]),
        ],
        maxTokens: 100,
        tools: [
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
        toolChoice: ToolChoice(mode: ToolChoiceMode.required),
      );
      final json = params.toJson();
      expect((json['tools'] as List).single['name'], 'get_weather');
      expect(json['toolChoice'], {'mode': 'required'});
      final parsed = CreateMessageRequestParams.fromJson(json);
      expect(parsed.tools!.single.name, 'get_weather');
      expect(parsed.toolChoice!.mode, ToolChoiceMode.required);
    });

    test('without tools the keys stay off the wire', () {
      final json = CreateMessageRequestParams(
        messages: [SamplingMessage(role: Role.user, content: [TextContent(text: 'hi')])],
        maxTokens: 10,
      ).toJson();
      expect(json.containsKey('tools'), isFalse);
      expect(json.containsKey('toolChoice'), isFalse);
    });

    test('a tool call is a tool_use content block', () {
      final result = CreateMessageResult(
        model: 'claude',
        role: Role.assistant,
        stopReason: 'toolUse',
        content: [
          ToolUseContent(id: 'u1', name: 'get_weather', input: {'city': 'Seoul'}),
        ],
      );
      final json = result.toJson();
      expect(json['content'], {
        'type': 'tool_use',
        'id': 'u1',
        'name': 'get_weather',
        'input': {'city': 'Seoul'},
      });
      final parsed = CreateMessageResult.fromJson(json);
      expect(parsed.content.single, isA<ToolUseContent>());
    });

    test('typed sampling handler receives the params over the wire', () async {
      final config = McpClient.productionConfig(
        name: 'A3 client',
        version: '1.0.0',
        capabilities: const ClientCapabilities(sampling: true, samplingTools: true),
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

      CreateMessageRequestParams? received;
      client.onSamplingRequest((req) async {
        received = req;
        return CreateMessageResult(
          model: 'claude',
          role: Role.assistant,
          stopReason: 'toolUse',
          content: [ToolUseContent(id: 'u1', name: 'get_weather', input: {'city': 'Seoul'})],
        );
      });

      await client.connect(transport, era: ProtocolEra.legacy);

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
            {'name': 'get_weather', 'description': 'Look up weather', 'inputSchema': {'type': 'object'}},
          ],
          'toolChoice': {'mode': 'auto'},
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, isNotNull);
      expect(received!.maxTokens, 100);
      expect(received!.messages.single.content.single, isA<TextContent>());
      expect(received!.tools!.single.name, 'get_weather');
      expect(received!.toolChoice!.mode, ToolChoiceMode.auto);

      final response = transport.sentMessages.firstWhere((m) => m['id'] == 42);
      expect((response['result'] as Map)['content']['type'], 'tool_use');

      client.disconnect();
    });
  });

  // --------------------------------------------------------------------------
  // A4 — Elicitation typed layer (generated schema types)
  // --------------------------------------------------------------------------
  group('A4 elicitation typed layer', () {
    test('form fields read as their primitive schema kind', () {
      final params = ElicitRequestParams.fromJson({
        'message': 'Tell us about yourself',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'default': 'Anon'},
            'color': {'type': 'string', 'enum': ['r', 'g']},
            'tags': {
              'type': 'array',
              'items': {'type': 'string', 'enum': ['a', 'b']},
              'default': ['a'],
            },
            'size': {'type': 'integer', 'minimum': 0, 'default': 5},
            'ok': {'type': 'boolean', 'default': true},
          },
          'required': ['name'],
        },
      });
      expect(params, isA<ElicitRequestFormParams>());
      final form = params as ElicitRequestFormParams;
      final props = (form.requestedSchema['properties'] as Map).map(
          (k, v) => MapEntry(k as String, PrimitiveSchemaDefinition.fromJson(Map<String, Object?>.from(v as Map))));
      expect(props['name'], isA<StringSchema>());
      expect((props['name'] as StringSchema).defaultValue, 'Anon');
      expect(props['color'], isA<UntitledSingleSelectEnumSchema>());
      expect(props['tags'], isA<UntitledMultiSelectEnumSchema>());
      expect((props['size'] as NumberSchema).type, NumberSchemaType.integer);
      expect((props['ok'] as BooleanSchema).defaultValue, isTrue);
    });

    test('url mode (SEP-1036)', () {
      final params = ElicitRequestParams.fromJson({
        'message': 'Complete auth in browser',
        'mode': 'url',
        'url': 'https://example.com/consent',
        'elicitationId': 'e1',
      });
      expect(params, isA<ElicitRequestURLParams>());
      expect((params as ElicitRequestURLParams).url, 'https://example.com/consent');
    });

    test('ElicitResult actions', () {
      expect(ElicitResult(action: ElicitResultAction.accept, content: {'name': 'x'}).toJson(),
          {'action': 'accept', 'content': {'name': 'x'}});
      expect(ElicitResult(action: ElicitResultAction.decline).toJson(), {'action': 'decline'});
      expect(ElicitResult(action: ElicitResultAction.cancel).toJson(), {'action': 'cancel'});
    });

    test('typed elicitation handler dispatches over the wire', () async {
      final config = McpClient.productionConfig(
        name: 'A4 client',
        version: '1.0.0',
        capabilities: const ClientCapabilities(elicitation: true, elicitationForm: true),
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

      ElicitRequestParams? received;
      client.onElicitationRequestTyped((req) async {
        received = req;
        return ElicitResult(action: ElicitResultAction.accept, content: {'color': 'g'});
      });

      await client.connect(transport, era: ProtocolEra.legacy);

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
                'oneOf': [
                  {'const': 'r', 'title': 'Red'},
                  {'const': 'g', 'title': 'Green'},
                ],
              },
            },
          },
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, isA<ElicitRequestFormParams>());
      final response = transport.sentMessages.firstWhere((m) => m['id'] == 77);
      expect(response['result'], {
        'action': 'accept',
        'content': {'color': 'g'},
      });
      client.disconnect();
    });
  });

  // --------------------------------------------------------------------------
  // A9 — Implementation.description
  // --------------------------------------------------------------------------
  group('A9 Implementation.description', () {
    test('ClientInfo/ServerInfo description round-trip', () {
      final ci = ClientInfo(
        name: 'c',
        version: '1.0.0',
        description: 'A test client',
      );
      expect(ci.toJson()['description'], equals('A test client'));
      expect(
        ClientInfo.fromJson(ci.toJson()).description,
        equals('A test client'),
      );

      final si = ServerInfo(
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

      await client.connect(transport, era: ProtocolEra.legacy);

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

      await client.connect(transport, era: ProtocolEra.legacy);

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
