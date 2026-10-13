/// Caller-supplied request `_meta` (the `meta` parameter on request methods).
///
/// A forwarding host relays its caller's context in the request `_meta`, so
/// every surface it forwards must accept one. Verifies that:
///  - tools, resources, prompts, completion, lists, tasks and ping all send it,
///  - on the stateless path it sits next to the reserved keys, which win,
///  - the legacy (handshake) path sends it verbatim,
///  - an omitted `meta` sends no `_meta` on the legacy path.
@TestOn('vm')
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

const _key = 'app.example/access';
const _meta = {
  _key: {'member': 'm-1', 'unit': 'u-7'},
};

Map<String, dynamic> _ok(Map<String, dynamic> result) => {
  'jsonrpc': '2.0',
  'result': result,
};

Map<String, dynamic>? _sentMeta(MockTransport t, String method) {
  final req = t.sentMessages.lastWhere((m) => m['method'] == method);
  final meta = (req['params'] as Map)['_meta'];
  return meta == null ? null : Map<String, dynamic>.from(meta as Map);
}

void main() {
  group('request meta on the stateless path', () {
    late MockTransport transport;
    late Client client;

    setUp(() async {
      transport = MockTransport();
      client = Client(name: 'fwd', version: '1.0.0');
      await client.connect(transport, era: ProtocolEra.modern);
    });

    final calls = <String, Future<void> Function(Client)>{
      'tools/list': (c) => c.listTools(meta: _meta),
      'tools/call': (c) => c.callTool('t', const {}, meta: _meta),
      'resources/list': (c) => c.listResources(meta: _meta),
      'resources/read': (c) => c.readResource('test://r', meta: _meta),
      'resources/templates/list': (c) => c.listResourceTemplates(meta: _meta),
      'prompts/list': (c) => c.listPrompts(meta: _meta),
      'prompts/get': (c) => c.getPrompt('p', null, _meta),
      'completion/complete':
          (c) => c.complete(
            const {'type': 'ref/prompt', 'name': 'p'},
            const {'name': 'a', 'value': ''},
            meta: _meta,
          ),
      'tasks/get': (c) => c.getTask('task-1', meta: _meta),
      'tasks/update': (c) => c.updateTask('task-1', const {}, meta: _meta),
      'tasks/cancel': (c) => c.cancelTask('task-1', meta: _meta),
    };

    const results = <String, Map<String, dynamic>>{
      'tools/list': {'tools': <dynamic>[]},
      'tools/call': {'content': <dynamic>[]},
      'resources/list': {'resources': <dynamic>[]},
      'resources/read': {'contents': <dynamic>[]},
      'resources/templates/list': {'resourceTemplates': <dynamic>[]},
      'prompts/list': {'prompts': <dynamic>[]},
      'prompts/get': {'messages': <dynamic>[]},
      'completion/complete': {
        'completion': {'values': <dynamic>[]},
      },
      'tasks/get': {
        'taskId': 'task-1',
        'status': 'working',
        'createdAt': '2026-10-12T00:00:00Z',
        'lastUpdatedAt': '2026-10-12T00:00:00Z',
        'ttl': null,
      },
    };

    for (final entry in calls.entries) {
      test('${entry.key} carries the caller meta', () async {
        transport.queueResponse(_ok(results[entry.key] ?? const {}));
        await entry.value(client);

        final meta = _sentMeta(transport, entry.key)!;
        expect(meta[_key], {'member': 'm-1', 'unit': 'u-7'});
        expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      });
    }

    test('ping, which 2026-07-28 does not define, is refused, not sent', () async {
      await expectLater(client.ping(meta: _meta), throwsA(isA<McpError>().having((e) => e.code, 'code', -32601)));
      expect(transport.sentMessages, isEmpty);
    });

    test('subscribeResource is carried on subscriptions/listen (no resources/subscribe)', () async {
      final done = client.subscribeResource('test://r', meta: _meta);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final listen = transport.sentMessages.single as Map;
      expect(listen['method'], 'subscriptions/listen');
      expect(listen['params']['notifications'], {'resourceSubscriptions': ['test://r']});
      transport.simulateMessage({
        'jsonrpc': '2.0',
        'method': 'notifications/subscriptions/acknowledged',
        'params': {
          'notifications': {'resourceSubscriptions': ['test://r']},
          '_meta': {'io.modelcontextprotocol/subscriptionId': listen['id']},
        },
      });
      await done;
      expect(transport.sentMessages.where((m) => m['method'] == 'resources/subscribe'), isEmpty);
    });

    test('reserved keys win over caller-supplied values', () async {
      transport.queueResponse(_ok({'tools': <dynamic>[]}));
      await client.listTools(
        meta: {McpRequestMeta.keyProtocolVersion: '1999-01-01', _key: 'x'},
      );

      final meta = _sentMeta(transport, 'tools/list')!;
      expect(meta[McpRequestMeta.keyProtocolVersion], '2026-07-28');
      expect(meta[_key], 'x');
    });
  });

  group('request meta on the legacy path', () {
    late MockTransport transport;
    late Client client;

    setUp(() async {
      transport = MockTransport();
      transport.queueResponse(
        _ok({
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {
            'tools': <String, dynamic>{},
            'resources': <String, dynamic>{},
            'prompts': <String, dynamic>{},
          },
        }),
      );
      client = Client(name: 'fwd', version: '1.0.0');
      await client.connect(transport, era: ProtocolEra.legacy);
    });

    test('meta is sent verbatim', () async {
      transport.queueResponse(_ok({'content': <dynamic>[]}));
      await client.callTool('t', const {}, meta: _meta);
      expect(_sentMeta(transport, 'tools/call'), _meta);
    });

    test('no meta sends no _meta', () async {
      transport.queueResponse(_ok({'content': <dynamic>[]}));
      await client.callTool('t', const {});
      expect(_sentMeta(transport, 'tools/call'), isNull);
    });

    test('getPrompt keeps arguments and carries meta', () async {
      transport.queueResponse(_ok({'messages': <dynamic>[]}));
      await client.getPrompt('p', const {'a': '1'}, _meta);
      final req = transport.sentMessages.lastWhere(
        (m) => m['method'] == 'prompts/get',
      );
      final params = req['params'] as Map;
      expect(params['arguments'], {'a': '1'});
      expect(params['_meta'], _meta);
    });
  });
}
