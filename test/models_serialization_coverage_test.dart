/// Client-side value types: the package's own classes (JSON-RPC message,
/// health, pending operations, progress, cache, capabilities, tool metadata)
/// and the protocol types as this client reads them (generated schema types —
/// their field-level round trip is covered exhaustively in `mcp_schema`).
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('protocol types as the client reads them', () {
    test('ContentBlock dispatch keeps an unknown kind', () {
      expect(ContentBlock.fromJson({'type': 'resource_link', 'uri': 'file:///a', 'name': 'a'}),
          isA<ResourceLink>());
      final unknown = ContentBlock.fromJson({'type': 'hologram'});
      expect(unknown, isA<UnknownContentBlock>());
      expect(unknown.toJson(), {'type': 'hologram'});
    });

    test('Tool keeps every field and what it does not model', () {
      final json = {
        'name': 'echo',
        'title': 'Echo',
        'description': 'd',
        'inputSchema': {'type': 'object'},
        'outputSchema': {'type': 'object'},
        'annotations': {'readOnlyHint': true},
        'execution': {'taskSupport': 'optional'},
        'icons': [
          {'src': 'https://example.com/i.png'}
        ],
        '_meta': {'io.example/k': 1},
        'io.example/vendor': true,
      };
      final tool = Tool.fromJson(json);
      expect(tool.annotations!.readOnlyHint, isTrue);
      expect(tool.execution!.taskSupport, ToolExecutionTaskSupport.optional);
      expect(tool.check(), isEmpty);
      expect(tool.toJson(), json);
    });

    test('CallToolResult with structuredContent and isError', () {
      final r = CallToolResult.fromJson({
        'content': [
          {'type': 'text', 'text': 'x'}
        ],
        'structuredContent': {'v': 1},
        'isError': true,
      });
      expect(r.structuredContent, {'v': 1});
      expect(r.isError, isTrue);
      expect(r.content.single, isA<TextContent>());
    });

    test('ReadResourceResult contents read by kind; 2.x accessors still work', () {
      final r = ReadResourceResult.fromJson({
        'contents': [
          {'uri': 'file:///a', 'mimeType': 'text/plain', 'text': 'hi'},
          {'uri': 'file:///b', 'blob': 'YQ=='},
        ],
      });
      expect(r.contents[0], isA<TextResourceContents>());
      expect(r.contents[0].text, 'hi');
      expect(r.contents[0].mimeType, 'text/plain');
      expect(r.contents[1].blob, 'YQ==');
      expect(r.contents[1].uri, 'file:///b');
      expect(r.contents[1].text, isNull);
    });

    test('list results carry nextCursor and _meta', () {
      final r = ListToolsResult.fromJson({
        'tools': [
          {'name': 't', 'inputSchema': {'type': 'object'}}
        ],
        'nextCursor': 'c2',
        '_meta': {'io.example/k': 1},
      });
      expect(r.nextCursor, 'c2');
      expect(r.tools.single.name, 't');
      expect(r.toJson()['_meta'], {'io.example/k': 1});
    });

    test('InitializeResult reads instructions and every serverInfo field', () {
      final r = InitializeResult.fromJson({
        'protocolVersion': '2025-11-25',
        'capabilities': {'tools': {'listChanged': true}},
        'serverInfo': {
          'name': 's',
          'version': '1',
          'title': 'S',
          'websiteUrl': 'https://example.com',
          'icons': [
            {'src': 'https://example.com/i.png'}
          ],
        },
        'instructions': 'Use tools.',
      });
      expect(r.instructions, 'Use tools.');
      expect(r.serverInfo.title, 'S');
      expect(r.serverInfo.websiteUrl, 'https://example.com');
      expect(r.check(), isEmpty);
    });

    test('2.x helpers build the schema types', () {
      expect(ResourceContentInfo(uri: 'u', text: 't'), isA<TextResourceContents>());
      expect(Message(role: 'assistant', content: TextContent(text: 'x')).role, Role.assistant);
      expect(ResourceContent(uri: 'u', text: 't').resource, isA<TextResourceContents>());
    });
  });

  group('ClientCapabilities', () {
    test('roots without listChanged', () {
      final caps = ClientCapabilities.fromJson({'roots': <String, dynamic>{}});
      expect(caps.roots, isTrue);
      expect(caps.rootsListChanged, isFalse);
    });

    test('every sub-field round-trips', () {
      final json = {
        'roots': {'listChanged': true},
        'sampling': {'context': <String, dynamic>{}, 'tools': <String, dynamic>{}},
        'elicitation': {'form': <String, dynamic>{}, 'url': <String, dynamic>{}},
        'tasks': {'list': <String, dynamic>{}},
        'experimental': {'x': <String, dynamic>{}},
        'extensions': {'io.modelcontextprotocol/tasks': <String, dynamic>{}},
      };
      final caps = ClientCapabilities.fromJson(json);
      expect(caps.samplingContext, isTrue);
      expect(caps.samplingTools, isTrue);
      expect(caps.elicitationForm, isTrue);
      expect(caps.elicitationUrl, isTrue);
      expect(caps.toJson(), json);
    });
  });

  group('ServerCapabilities', () {
    test('equal JSON means equal', () {
      bool flag = true;
      final a = ServerCapabilities(tools: flag, resources: flag);
      final b = ServerCapabilities(tools: flag, resources: flag);
      const c = ServerCapabilities(tools: false);
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('every field the protocol defines', () {
      final json = {
        'tools': {'listChanged': true},
        'resources': {'subscribe': true, 'listChanged': true},
        'prompts': {'listChanged': true},
        'logging': <String, dynamic>{},
        'completions': <String, dynamic>{},
        'tasks': {'list': <String, dynamic>{}},
        'experimental': {'x': <String, dynamic>{}},
        'extensions': {'io.modelcontextprotocol/tasks': <String, dynamic>{}},
      };
      final caps = ServerCapabilities.fromJson(json);
      expect(caps.resourcesSubscribe, isTrue);
      expect(caps.completions, isTrue);
      expect(caps.hasExtension('io.modelcontextprotocol/tasks'), isTrue);
      expect(caps.toJson(), json);
    });

    test('a field this class does not name survives in raw', () {
      final caps = ServerCapabilities.fromJson({
        'tools': <String, dynamic>{},
        'io.example/future': {'on': true},
      });
      expect(caps.raw!.extra, {'io.example/future': {'on': true}});
      expect(caps.toJson()['io.example/future'], {'on': true});
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
        content: ReadResourceResult(contents: []),
        cachedAt: DateTime.now(),
        maxAge: const Duration(minutes: 5),
      );
      expect(fresh.isExpired, isFalse);

      final stale = CachedResource(
        uri: 'file:///a',
        content: ReadResourceResult(contents: []),
        cachedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        maxAge: const Duration(minutes: 5),
      );
      expect(stale.isExpired, isTrue);
    });

    test('toJson serializes fields', () {
      final resource = CachedResource(
        uri: 'file:///a',
        content: ReadResourceResult(contents: []),
        cachedAt: DateTime.utc(2024, 1, 1),
        maxAge: const Duration(seconds: 30),
      );
      final json = resource.toJson();
      expect(json['uri'], 'file:///a');
      expect(json['maxAgeSeconds'], 30);
      expect(json['content'], {'contents': []});
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
