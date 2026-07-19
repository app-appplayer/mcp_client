/// Exhaustive toJson/fromJson round-trip coverage for `lib/src/models/models.dart`.
///
/// Targets branches left uncovered by the integration-style tests elsewhere
/// in this suite: optional-field presence/absence toggles, alternate wire
/// formats (nested vs flat resource content), and the `Content.fromJson`
/// type dispatcher including the unknown-type error path.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('Content.fromJson dispatch', () {
    test('dispatches resource_link type', () {
      final content = Content.fromJson({
        'type': 'resource_link',
        'uri': 'file:///a.txt',
      });
      expect(content, isA<ResourceLinkContent>());
      expect((content as ResourceLinkContent).uri, 'file:///a.txt');
    });

    test('throws ArgumentError on unknown type', () {
      expect(
        () => Content.fromJson({'type': 'bogus'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AudioContent', () {
    test('round-trips with annotations', () {
      const content = AudioContent(
        data: 'base64data',
        mimeType: 'audio/mpeg',
        annotations: {'audience': 'assistant'},
      );
      final json = content.toJson();
      expect(json['type'], 'audio');
      expect(json['data'], 'base64data');
      expect(json['mimeType'], 'audio/mpeg');
      expect(json['annotations'], {'audience': 'assistant'});

      final decoded = AudioContent.fromJson(json);
      expect(decoded.data, content.data);
      expect(decoded.mimeType, content.mimeType);
      expect(decoded.annotations, content.annotations);
    });

    test('round-trips without annotations', () {
      const content = AudioContent(data: 'd', mimeType: 'audio/wav');
      final json = content.toJson();
      expect(json.containsKey('annotations'), isFalse);
      final decoded = AudioContent.fromJson(json);
      expect(decoded.annotations, isNull);
    });
  });

  group('ResourceLinkContent', () {
    test('round-trips with all optional fields', () {
      const content = ResourceLinkContent(
        uri: 'file:///a.txt',
        name: 'a.txt',
        description: 'A file',
        mimeType: 'text/plain',
        annotations: {'x': 1},
        meta: {'y': 2},
      );
      final json = content.toJson();
      expect(json['type'], 'resource_link');
      expect(json['uri'], 'file:///a.txt');
      expect(json['name'], 'a.txt');
      expect(json['description'], 'A file');
      expect(json['mimeType'], 'text/plain');
      expect(json['annotations'], {'x': 1});
      expect(json['_meta'], {'y': 2});

      final decoded = ResourceLinkContent.fromJson(json);
      expect(decoded.uri, content.uri);
      expect(decoded.name, content.name);
      expect(decoded.description, content.description);
      expect(decoded.mimeType, content.mimeType);
      expect(decoded.annotations, content.annotations);
      expect(decoded.meta, content.meta);
    });

    test('round-trips with only required field', () {
      const content = ResourceLinkContent(uri: 'file:///b.txt');
      final json = content.toJson();
      expect(json.keys, containsAll(['type', 'uri']));
      expect(json.containsKey('name'), isFalse);
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('mimeType'), isFalse);
      expect(json.containsKey('annotations'), isFalse);
      expect(json.containsKey('_meta'), isFalse);

      final decoded = ResourceLinkContent.fromJson(json);
      expect(decoded.uri, content.uri);
      expect(decoded.name, isNull);
      expect(decoded.meta, isNull);
    });
  });

  group('ImageContent', () {
    test('fromBase64 factory builds data-based content', () {
      final content =
          ImageContent.fromBase64(data: 'b64==', mimeType: 'image/png');
      expect(content.data, 'b64==');
      expect(content.mimeType, 'image/png');
      expect(content.url, isNull);
    });

    test('toJson prefers data over url when both null vs data set', () {
      const withData = ImageContent(
        data: 'b64==',
        mimeType: 'image/png',
        annotations: {'k': 'v'},
      );
      final json = withData.toJson();
      expect(json['data'], 'b64==');
      expect(json.containsKey('url'), isFalse);
      expect(json['annotations'], {'k': 'v'});
    });

    test('toJson falls back to url when data is null', () {
      const withUrl = ImageContent(
        url: 'https://example.com/a.png',
        mimeType: 'image/png',
      );
      final json = withUrl.toJson();
      expect(json['url'], 'https://example.com/a.png');
      expect(json.containsKey('data'), isFalse);
    });
  });

  group('ResourceContent', () {
    test('toJson emits all optional fields inside nested resource', () {
      const content = ResourceContent(
        uri: 'file:///r.txt',
        text: 'hello',
        blob: 'blobdata',
        mimeType: 'text/plain',
        annotations: {'a': 1},
      );
      final json = content.toJson();
      expect(json['type'], 'resource');
      final resource = json['resource'] as Map<String, dynamic>;
      expect(resource['uri'], 'file:///r.txt');
      expect(resource['text'], 'hello');
      expect(resource['blob'], 'blobdata');
      expect(resource['mimeType'], 'text/plain');
      expect(json['annotations'], {'a': 1});
    });

    test('fromJson parses nested 2025 format', () {
      final decoded = ResourceContent.fromJson({
        'type': 'resource',
        'resource': {
          'uri': 'file:///r.txt',
          'text': 'hello',
          'blob': 'blobdata',
          'mimeType': 'text/plain',
        },
        'annotations': {'a': 1},
      });
      expect(decoded.uri, 'file:///r.txt');
      expect(decoded.text, 'hello');
      expect(decoded.blob, 'blobdata');
      expect(decoded.mimeType, 'text/plain');
      expect(decoded.annotations, {'a': 1});
    });

    test('fromJson parses older flat format', () {
      final decoded = ResourceContent.fromJson({
        'uri': 'file:///flat.txt',
        'text': 'flat text',
      });
      expect(decoded.uri, 'file:///flat.txt');
      expect(decoded.text, 'flat text');
    });
  });

  group('Tool', () {
    test('toJson/fromJson round-trip icons and metadata', () {
      const tool = Tool(
        name: 'search',
        title: 'Search Tool',
        description: 'Searches things',
        inputSchema: {'type': 'object'},
        outputSchema: {'type': 'object'},
        icons: [
          {'src': 'icon.png', 'sizes': '48x48'},
        ],
        meta: {'m': 1},
        supportsProgress: true,
        supportsCancellation: true,
        metadata: {'extra': 'data'},
      );
      final json = tool.toJson();
      expect(json['icons'], [
        {'src': 'icon.png', 'sizes': '48x48'},
      ]);
      expect(json['_meta'], {'m': 1});
      expect(json['metadata'], {'extra': 'data'});

      final decoded = Tool.fromJson(json);
      expect(decoded.name, tool.name);
      expect(decoded.title, tool.title);
      expect(decoded.icons, tool.icons);
      expect(decoded.meta, tool.meta);
      expect(decoded.supportsProgress, isTrue);
      expect(decoded.supportsCancellation, isTrue);
      expect(decoded.metadata, tool.metadata);
    });
  });

  group('CallToolResult', () {
    test('toJson emits structuredContent and isError when present', () {
      const result = CallToolResult(
        [TextContent(text: 'hi')],
        structuredContent: {'ok': true},
        isStreaming: true,
        isError: true,
      );
      final json = result.toJson();
      expect(json['structuredContent'], {'ok': true});
      expect(json['isStreaming'], isTrue);
      expect(json['isError'], isTrue);
      expect((json['content'] as List).length, 1);
    });

    test('fromJson round-trips a minimal result', () {
      final json = const CallToolResult([TextContent(text: 'hi')]).toJson();
      final decoded = CallToolResult.fromJson(json);
      expect(decoded.content.length, 1);
      expect(decoded.isError, isNull);
      expect(decoded.isStreaming, isFalse);
    });
  });

  group('Resource', () {
    test('toJson/fromJson round-trip all optional fields', () {
      const resource = Resource(
        uri: 'file:///a.txt',
        name: 'a.txt',
        title: 'A',
        description: 'desc',
        mimeType: 'text/plain',
        icons: [
          {'src': 'i.png'},
        ],
        meta: {'m': 1},
        metadata: {'extra': true},
      );
      final json = resource.toJson();
      expect(json['title'], 'A');
      expect(json['mimeType'], 'text/plain');
      expect(json['icons'], [
        {'src': 'i.png'},
      ]);
      expect(json['_meta'], {'m': 1});
      expect(json['metadata'], {'extra': true});

      final decoded = Resource.fromJson(json);
      expect(decoded.title, resource.title);
      expect(decoded.icons, resource.icons);
      expect(decoded.meta, resource.meta);
      expect(decoded.metadata, resource.metadata);
    });
  });

  group('ResourceContentInfo / ReadResourceResult', () {
    test('ResourceContentInfo.toJson emits all optional fields', () {
      const info = ResourceContentInfo(
        uri: 'file:///a.txt',
        mimeType: 'text/plain',
        text: 'hi',
        blob: 'b',
      );
      final json = info.toJson();
      expect(json, {
        'uri': 'file:///a.txt',
        'mimeType': 'text/plain',
        'text': 'hi',
        'blob': 'b',
      });
    });

    test('ReadResourceResult toJson wraps contents', () {
      const result = ReadResourceResult(
        contents: [ResourceContentInfo(uri: 'file:///a.txt', text: 'hi')],
      );
      final json = result.toJson();
      expect((json['contents'] as List).length, 1);
    });

    test('ReadResourceResult.fromJson parses contents list', () {
      final decoded = ReadResourceResult.fromJson({
        'contents': [
          {'uri': 'file:///a.txt', 'text': 'hi', 'mimeType': 'text/plain'},
        ],
      });
      expect(decoded.contents.length, 1);
      expect(decoded.contents.first.uri, 'file:///a.txt');
      expect(decoded.contents.first.text, 'hi');
      expect(decoded.contents.first.mimeType, 'text/plain');
    });

    test('ReadResourceResult.fromJson defaults to empty when absent', () {
      final decoded = ReadResourceResult.fromJson(const {});
      expect(decoded.contents, isEmpty);
    });
  });

  group('PromptArgument', () {
    test('toJson/fromJson round-trip with description and default', () {
      const arg = PromptArgument(
        name: 'x',
        description: 'desc',
        required: true,
        defaultValue: 'dv',
      );
      final json = arg.toJson();
      expect(json, {
        'name': 'x',
        'required': true,
        'description': 'desc',
        'default': 'dv',
      });

      final decoded = PromptArgument.fromJson(json);
      expect(decoded.name, 'x');
      expect(decoded.description, 'desc');
      expect(decoded.required, isTrue);
      expect(decoded.defaultValue, 'dv');
    });

    test('toJson omits absent optionals', () {
      const arg = PromptArgument(name: 'y');
      final json = arg.toJson();
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('default'), isFalse);
      expect(json['required'], isFalse);
    });
  });

  group('Prompt', () {
    test('toJson/fromJson round-trip all optional fields', () {
      const prompt = Prompt(
        name: 'greet',
        title: 'Greeting',
        description: 'says hi',
        arguments: [PromptArgument(name: 'who', required: true)],
        icons: [
          {'src': 'p.png'},
        ],
        meta: {'m': 1},
        metadata: {'e': true},
      );
      final json = prompt.toJson();
      expect(json['title'], 'Greeting');
      expect(json['description'], 'says hi');
      expect(json['icons'], [
        {'src': 'p.png'},
      ]);
      expect(json['_meta'], {'m': 1});
      expect(json['metadata'], {'e': true});
      expect((json['arguments'] as List).length, 1);

      final decoded = Prompt.fromJson(json);
      expect(decoded.title, prompt.title);
      expect(decoded.description, prompt.description);
      expect(decoded.arguments.length, 1);
      expect(decoded.arguments.first.name, 'who');
      expect(decoded.icons, prompt.icons);
      expect(decoded.meta, prompt.meta);
      expect(decoded.metadata, prompt.metadata);
    });
  });

  group('GetPromptResult', () {
    test('toJson/fromJson round-trip with description', () {
      const result = GetPromptResult(
        description: 'a prompt result',
        messages: [Message(role: 'user', content: TextContent(text: 'hi'))],
      );
      final json = result.toJson();
      expect(json['description'], 'a prompt result');
      expect((json['messages'] as List).length, 1);

      final decoded = GetPromptResult.fromJson(json);
      expect(decoded.description, 'a prompt result');
      expect(decoded.messages.length, 1);
      expect(decoded.messages.first.role, 'user');
    });
  });

  group('ModelHint / ModelPreferences', () {
    test('ModelHint round-trips with weight', () {
      const hint = ModelHint(name: 'gpt', weight: 0.75);
      final json = hint.toJson();
      expect(json, {'name': 'gpt', 'weight': 0.75});
      final decoded = ModelHint.fromJson(json);
      expect(decoded.name, 'gpt');
      expect(decoded.weight, 0.75);
    });

    test('ModelHint round-trips without weight', () {
      const hint = ModelHint(name: 'gpt');
      final json = hint.toJson();
      expect(json.containsKey('weight'), isFalse);
      final decoded = ModelHint.fromJson(json);
      expect(decoded.weight, isNull);
    });

    test('ModelPreferences round-trips all fields', () {
      const prefs = ModelPreferences(
        hints: [ModelHint(name: 'gpt', weight: 1.0)],
        costPriority: 0.1,
        speedPriority: 0.2,
        intelligencePriority: 0.3,
      );
      final json = prefs.toJson();
      expect((json['hints'] as List).length, 1);
      expect(json['costPriority'], 0.1);
      expect(json['speedPriority'], 0.2);
      expect(json['intelligencePriority'], 0.3);

      final decoded = ModelPreferences.fromJson(json);
      expect(decoded.hints!.length, 1);
      expect(decoded.costPriority, 0.1);
      expect(decoded.speedPriority, 0.2);
      expect(decoded.intelligencePriority, 0.3);
    });

    test('ModelPreferences empty hints list is omitted', () {
      const prefs = ModelPreferences(hints: []);
      final json = prefs.toJson();
      expect(json.containsKey('hints'), isFalse);
    });

    test('ModelPreferences.fromJson tolerates absent fields', () {
      final decoded = ModelPreferences.fromJson(const {});
      expect(decoded.hints, isNull);
      expect(decoded.costPriority, isNull);
      expect(decoded.speedPriority, isNull);
      expect(decoded.intelligencePriority, isNull);
    });
  });

  group('CreateMessageRequest', () {
    test('toJson emits all optional fields', () {
      const request = CreateMessageRequest(
        messages: [Message(role: 'user', content: TextContent(text: 'hi'))],
        modelPreferences: ModelPreferences(costPriority: 0.5),
        systemPrompt: 'be nice',
        includeContext: 'thisServer',
        maxTokens: 100,
        temperature: 0.5,
        stopSequences: ['STOP'],
        metadata: {'k': 'v'},
      );
      final json = request.toJson();
      expect(json['modelPreferences'], isNotNull);
      expect(json['systemPrompt'], 'be nice');
      expect(json['includeContext'], 'thisServer');
      expect(json['temperature'], 0.5);
      expect(json['stopSequences'], ['STOP']);
      expect(json['metadata'], {'k': 'v'});
    });

    test('fromJson parses all optional fields', () {
      final decoded = CreateMessageRequest.fromJson({
        'messages': [
          {
            'role': 'user',
            'content': {'type': 'text', 'text': 'hi'},
          },
        ],
        'modelPreferences': {'costPriority': 0.5},
        'stopSequences': ['A', 'B'],
        'temperature': 1,
        'metadata': {'k': 'v'},
        'tools': [
          {
            'name': 't1',
            'description': 'a tool',
            'inputSchema': {'type': 'object'},
          },
        ],
        'toolChoice': 'auto',
      });
      expect(decoded.modelPreferences!.costPriority, 0.5);
      expect(decoded.stopSequences, ['A', 'B']);
      expect(decoded.temperature, 1.0);
      expect(decoded.metadata, {'k': 'v'});
      expect(decoded.tools!.length, 1);
      expect(decoded.tools!.first.name, 't1');
      expect(decoded.toolChoice, 'auto');
    });

    test('SamplingToolChoice helpers produce canonical shapes', () {
      expect(SamplingToolChoice.auto, 'auto');
      expect(SamplingToolChoice.none, 'none');
      expect(SamplingToolChoice.required, 'required');
      expect(SamplingToolChoice.tool('t1'), {'type': 'tool', 'name': 't1'});
    });
  });

  group('Root', () {
    test('toJson emits description when set', () {
      const root = Root(uri: 'file:///r', name: 'r', description: 'a root');
      final json = root.toJson();
      expect(json['description'], 'a root');
    });

    test('fromJson parses all fields', () {
      final decoded = Root.fromJson({
        'uri': 'file:///r',
        'name': 'r',
        'description': 'a root',
      });
      expect(decoded.uri, 'file:///r');
      expect(decoded.name, 'r');
      expect(decoded.description, 'a root');
    });
  });

  group('JsonRpcMessage', () {
    test('toJson emits all optional fields when set', () {
      const message = JsonRpcMessage(
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/list',
        params: {'a': 1},
        result: {'b': 2},
        error: {'code': -1, 'message': 'x'},
      );
      final json = message.toJson();
      expect(json['id'], 1);
      expect(json['method'], 'tools/list');
      expect(json['params'], {'a': 1});
      expect(json['result'], {'b': 2});
      expect(json['error'], {'code': -1, 'message': 'x'});
    });

    test('fromJson throws FormatException on non-Map params', () {
      expect(
        () => JsonRpcMessage.fromJson({
          'jsonrpc': '2.0',
          'method': 'x',
          'params': 'not-a-map',
        }),
        throwsFormatException,
      );
    });

    test('fromJson throws FormatException on non-Map error', () {
      expect(
        () => JsonRpcMessage.fromJson({
          'jsonrpc': '2.0',
          'id': 1,
          'error': 'not-a-map',
        }),
        throwsFormatException,
      );
    });
  });

  group('ServerHealth', () {
    test('fromJson parses all present fields', () {
      final health = ServerHealth.fromJson({
        'status': 'degraded',
        'version': '1.0.0',
        'connections': 5,
        'isRunning': true,
        'connectedSessions': 3,
        'registeredTools': 2,
        'registeredResources': 1,
        'registeredPrompts': 4,
        'startTime': '2024-01-01T00:00:00.000Z',
        'uptimeSeconds': 3600,
        'metrics': {'cpu': 0.5},
      });
      expect(health.status, 'degraded');
      expect(health.version, '1.0.0');
      expect(health.connections, 5);
      expect(health.uptime, const Duration(seconds: 3600));
      expect(health.metrics, {'cpu': 0.5});
    });

    test('fromJson applies defaults for absent fields', () {
      final health = ServerHealth.fromJson(const {});
      expect(health.status, 'healthy');
      expect(health.version, isNull);
      expect(health.connections, 0);
      expect(health.isRunning, isTrue);
      expect(health.connectedSessions, 0);
      expect(health.uptime, Duration.zero);
      expect(health.metrics, <String, dynamic>{});
    });

    test('toJson serializes running snapshot', () {
      final health = ServerHealth(
        isRunning: true,
        connectedSessions: 2,
        registeredTools: 1,
        registeredResources: 1,
        registeredPrompts: 1,
        startTime: DateTime.utc(2024, 1, 1),
        uptime: const Duration(seconds: 42),
        metrics: const {'k': 1},
      );
      final json = health.toJson();
      expect(json['isRunning'], isTrue);
      expect(json['connectedSessions'], 2);
      expect(json['uptimeSeconds'], 42);
      expect(json['metrics'], {'k': 1});
    });
  });

  group('PendingOperation', () {
    test('toJson/fromJson round-trip with requestId and cancellation', () {
      final op = PendingOperation(
        id: 'op-1',
        sessionId: 'sess-1',
        type: 'tool:calc',
        createdAt: DateTime.utc(2024, 1, 1),
        requestId: 'req-1',
      );
      op.isCancelled = true;
      final json = op.toJson();
      expect(json['requestId'], 'req-1');
      expect(json['isCancelled'], isTrue);

      final decoded = PendingOperation.fromJson(json);
      expect(decoded.id, 'op-1');
      expect(decoded.sessionId, 'sess-1');
      expect(decoded.type, 'tool:calc');
      expect(decoded.requestId, 'req-1');
      expect(decoded.isCancelled, isTrue);
    });

    test('toJson omits requestId when absent', () {
      final op = PendingOperation(
        id: 'op-2',
        sessionId: 'sess-2',
        type: 'tool:x',
        createdAt: DateTime.utc(2024, 1, 1),
      );
      final json = op.toJson();
      expect(json.containsKey('requestId'), isFalse);
    });
  });

  group('ProgressUpdate', () {
    test('toJson/fromJson round-trip', () {
      const update = ProgressUpdate(
        requestId: 'r1',
        progress: 0.5,
        message: 'halfway',
      );
      final json = update.toJson();
      expect(json, {'requestId': 'r1', 'progress': 0.5, 'message': 'halfway'});

      final decoded = ProgressUpdate.fromJson(json);
      expect(decoded.requestId, 'r1');
      expect(decoded.progress, 0.5);
      expect(decoded.message, 'halfway');
    });
  });

  group('CachedResource', () {
    test('isExpired reflects age vs maxAge', () {
      final fresh = CachedResource(
        uri: 'file:///a',
        content: const ReadResourceResult(contents: []),
        cachedAt: DateTime.now(),
        maxAge: const Duration(minutes: 5),
      );
      expect(fresh.isExpired, isFalse);

      final stale = CachedResource(
        uri: 'file:///a',
        content: const ReadResourceResult(contents: []),
        cachedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        maxAge: const Duration(minutes: 5),
      );
      expect(stale.isExpired, isTrue);
    });

    test('toJson serializes fields', () {
      final resource = CachedResource(
        uri: 'file:///a',
        content: const ReadResourceResult(contents: []),
        cachedAt: DateTime.utc(2024, 1, 1),
        maxAge: const Duration(seconds: 30),
      );
      final json = resource.toJson();
      expect(json['uri'], 'file:///a');
      expect(json['maxAgeSeconds'], 30);
      expect(json['content'], {'contents': []});
    });
  });

  group('ClientCapabilities.fromJson defaults', () {
    test('roots without explicit listChanged defaults to false', () {
      final caps = ClientCapabilities.fromJson({'roots': <String, dynamic>{}});
      expect(caps.roots, isTrue);
      expect(caps.rootsListChanged, isFalse);
    });
  });

  group('ServerCapabilities equality/hash/toString', () {
    test('equal instances compare equal and share hashCode', () {
      // Non-const construction (via a mutable local) so `a` and `b` are
      // distinct object identities with equal field values — this forces
      // operator== to evaluate the full field-by-field comparison instead
      // of short-circuiting on `identical(this, other)`, which const
      // canonicalization would otherwise trigger for two `const` literals
      // with the same arguments.
      bool flag = true;
      final a = ServerCapabilities(tools: flag, resources: flag);
      flag = true;
      final b = ServerCapabilities(tools: flag, resources: flag);
      const c = ServerCapabilities(tools: false);

      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals('not a ServerCapabilities')));
    });

    test('toJson emits extensions when present', () {
      const caps = ServerCapabilities(
        tools: true,
        extensions: {
          'io.modelcontextprotocol/tasks': <String, dynamic>{},
        },
      );
      final json = caps.toJson();
      expect(json['extensions'], {
        'io.modelcontextprotocol/tasks': <String, dynamic>{},
      });
    });

    test('toString includes all fields', () {
      const caps = ServerCapabilities(
        tools: true,
        resources: true,
        prompts: true,
        logging: true,
        sampling: true,
      );
      final str = caps.toString();
      expect(str, contains('tools: true'));
      expect(str, contains('resources: true'));
      expect(str, contains('prompts: true'));
      expect(str, contains('logging: true'));
      expect(str, contains('sampling: true'));
    });
  });

  group('InitializeRequest / InitializeResult', () {
    test('InitializeRequest round-trips', () {
      const request = InitializeRequest(
        clientInfo: ClientInfo(name: 'c', version: '1.0'),
        protocolVersion: '2025-11-25',
      );
      final json = request.toJson();
      expect(json['protocolVersion'], '2025-11-25');

      final decoded = InitializeRequest.fromJson(json);
      expect(decoded.clientInfo.name, 'c');
      expect(decoded.protocolVersion, '2025-11-25');
    });

    test('InitializeResult round-trips with capabilities', () {
      const result = InitializeResult(
        serverInfo: ServerInfo(name: 's', version: '1.0'),
        protocolVersion: '2025-11-25',
        capabilities: {'tools': <String, dynamic>{}},
      );
      final json = result.toJson();
      expect(json['capabilities'], {'tools': <String, dynamic>{}});

      final decoded = InitializeResult.fromJson(json);
      expect(decoded.serverInfo.name, 's');
      expect(decoded.protocolVersion, '2025-11-25');
      expect(decoded.capabilities, {'tools': <String, dynamic>{}});
    });
  });

  group('List-changed notifications', () {
    test('ToolsListChangedNotification round-trips as empty object', () {
      const n = ToolsListChangedNotification();
      expect(n.toJson(), <String, dynamic>{});
      expect(
        ToolsListChangedNotification.fromJson(const {}),
        const ToolsListChangedNotification(),
      );
    });

    test('ResourcesListChangedNotification round-trips as empty object', () {
      const n = ResourcesListChangedNotification();
      expect(n.toJson(), <String, dynamic>{});
      expect(
        ResourcesListChangedNotification.fromJson(const {}),
        const ResourcesListChangedNotification(),
      );
    });

    test('PromptsListChangedNotification round-trips as empty object', () {
      const n = PromptsListChangedNotification();
      expect(n.toJson(), <String, dynamic>{});
      expect(
        PromptsListChangedNotification.fromJson(const {}),
        const PromptsListChangedNotification(),
      );
    });

    test('ResourceUpdatedNotification round-trips uri', () {
      const n = ResourceUpdatedNotification(uri: 'file:///a');
      final json = n.toJson();
      expect(json, {'uri': 'file:///a'});
      final decoded = ResourceUpdatedNotification.fromJson(json);
      expect(decoded.uri, 'file:///a');
    });
  });

  group('List*Result wrappers', () {
    test('ListToolsResult round-trips', () {
      const result = ListToolsResult(
        tools: [
          Tool(
            name: 't',
            description: 'd',
            inputSchema: {'type': 'object'},
          ),
        ],
      );
      final json = result.toJson();
      final decoded = ListToolsResult.fromJson(json);
      expect(decoded.tools.length, 1);
      expect(decoded.tools.first.name, 't');
    });

    test('ListResourcesResult round-trips', () {
      const result = ListResourcesResult(
        resources: [
          Resource(uri: 'file:///a', name: 'a', description: 'd'),
        ],
      );
      final json = result.toJson();
      final decoded = ListResourcesResult.fromJson(json);
      expect(decoded.resources.length, 1);
      expect(decoded.resources.first.uri, 'file:///a');
    });

    test('ListPromptsResult round-trips', () {
      const result = ListPromptsResult(
        prompts: [Prompt(name: 'p', arguments: [])],
      );
      final json = result.toJson();
      final decoded = ListPromptsResult.fromJson(json);
      expect(decoded.prompts.length, 1);
      expect(decoded.prompts.first.name, 'p');
    });
  });

  group('Request/result value objects', () {
    test('CallToolRequest round-trips with arguments', () {
      const request = CallToolRequest(name: 't', arguments: {'a': 1});
      final json = request.toJson();
      expect(json['arguments'], {'a': 1});
      final decoded = CallToolRequest.fromJson(json);
      expect(decoded.name, 't');
      expect(decoded.arguments, {'a': 1});
    });

    test('CallToolRequest omits arguments when absent', () {
      const request = CallToolRequest(name: 't');
      final json = request.toJson();
      expect(json.containsKey('arguments'), isFalse);
    });

    test('ReadResourceRequest round-trips', () {
      const request = ReadResourceRequest(uri: 'file:///a');
      final json = request.toJson();
      expect(json, {'uri': 'file:///a'});
      final decoded = ReadResourceRequest.fromJson(json);
      expect(decoded.uri, 'file:///a');
    });

    test('GetPromptRequest round-trips with arguments', () {
      const request = GetPromptRequest(name: 'p', arguments: {'x': 'y'});
      final json = request.toJson();
      expect(json['arguments'], {'x': 'y'});
      final decoded = GetPromptRequest.fromJson(json);
      expect(decoded.name, 'p');
      expect(decoded.arguments, {'x': 'y'});
    });

    test('CompletionRequest round-trips with argument', () {
      const request = CompletionRequest(
        ref: {'type': 'ref/prompt', 'name': 'p'},
        argument: {'name': 'x', 'value': 'y'},
      );
      final json = request.toJson();
      expect(json['argument'], {'name': 'x', 'value': 'y'});
      final decoded = CompletionRequest.fromJson(json);
      expect(decoded.ref, {'type': 'ref/prompt', 'name': 'p'});
      expect(decoded.argument, {'name': 'x', 'value': 'y'});
    });

    test('CompletionResult round-trips', () {
      const result = CompletionResult(
        completion: {'values': ['a', 'b']},
      );
      final json = result.toJson();
      final decoded = CompletionResult.fromJson(json);
      expect(decoded.completion, {'values': ['a', 'b']});
    });
  });

  group('Notifications', () {
    test('LogMessageNotification round-trips with logger and data', () {
      const notification = LogMessageNotification(
        level: McpLogLevel.warning,
        message: 'careful',
        logger: 'core',
        data: {'k': 'v'},
      );
      final json = notification.toJson();
      expect(json['level'], 'warning');
      expect(json['logger'], 'core');
      expect(json['data'], {'k': 'v'});

      final decoded = LogMessageNotification.fromJson(json);
      expect(decoded.level, McpLogLevel.warning);
      expect(decoded.message, 'careful');
      expect(decoded.logger, 'core');
      expect(decoded.data, {'k': 'v'});
    });

    test('CancelRequestNotification round-trips with reason', () {
      const notification =
          CancelRequestNotification(requestId: 'r1', reason: 'timeout');
      final json = notification.toJson();
      expect(json['reason'], 'timeout');
      final decoded = CancelRequestNotification.fromJson(json);
      expect(decoded.requestId, 'r1');
      expect(decoded.reason, 'timeout');
    });

    test('CancelRequestNotification omits reason when absent', () {
      const notification = CancelRequestNotification(requestId: 'r1');
      final json = notification.toJson();
      expect(json.containsKey('reason'), isFalse);
    });

    test('ProgressNotification round-trips with total', () {
      const notification =
          ProgressNotification(requestId: 'r1', progress: 0.5, total: 1.0);
      final json = notification.toJson();
      expect(json['total'], 1.0);
      final decoded = ProgressNotification.fromJson(json);
      expect(decoded.requestId, 'r1');
      expect(decoded.progress, 0.5);
      expect(decoded.total, 1.0);
    });

    test('ProgressNotification omits total when absent', () {
      const notification = ProgressNotification(requestId: 'r1', progress: 0.5);
      final json = notification.toJson();
      expect(json.containsKey('total'), isFalse);
      final decoded = ProgressNotification.fromJson(json);
      expect(decoded.total, isNull);
    });
  });

  group('ToolMetadata equality with matching name', () {
    test('differs when description differs but name matches', () {
      const a = ToolMetadata(name: 'x', description: 'one');
      const b = ToolMetadata(name: 'x', description: 'two');
      expect(a, isNot(equals(b)));
    });
  });
}
