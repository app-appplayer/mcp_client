/// 2026-07-28 stateless core R2 (SEP-2577) — client-side Multi-Round-Trip
/// driver + `subscriptions/listen` consumer + `resultType` handling, exercised
/// against a scripted in-memory transport (runs on VM and dart2js). No real
/// socket — this isolates the CLIENT MRTR/subscription logic. The full wire
/// round-trip is proven in `mcp_server`'s interop test.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:mcp_client/mcp_client.dart';

/// A scripted transport: a test supplies a responder that, given an outbound
/// request map, returns the JSON-RPC message(s) to feed back. Notifications
/// (no id) are dropped unless the responder emits for them.
class _ScriptedTransport implements ClientTransport {
  final _incoming = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();
  final List<Map<String, dynamic>> sent = [];

  /// Responder: outbound message → list of inbound messages to enqueue.
  final List<dynamic> Function(Map<String, dynamic> out) responder;

  _ScriptedTransport(this.responder);

  @override
  Stream<dynamic> get onMessage => _incoming.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final map = Map<String, dynamic>.from(message as Map);
    sent.add(map);
    // Reply asynchronously so the client's completer is registered first.
    scheduleMicrotask(() {
      for (final reply in responder(map)) {
        if (!_incoming.isClosed) _incoming.add(reply);
      }
    });
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _incoming.close();
  }
}

void main() {
  group('R2 client — MRTR driver', () {
    test('callTool drives input_required → elicit → re-issue → complete',
        () async {
      // Round 1: tools/call with no inputResponses → input_required (elicit).
      // Round 2: tools/call carrying inputResponses → terminal complete result.
      final transport = _ScriptedTransport((out) {
        if (out['method'] != 'tools/call') return const [];
        final id = out['id'];
        final params = out['params'] as Map;
        if (params['inputResponses'] == null) {
          return [
            {
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'resultType': 'input_required',
                'inputRequests': {
                  'ask': {
                    'method': 'elicitation/create',
                    'params': {
                      'message': 'name?',
                      'requestedSchema': {'type': 'object'},
                    },
                  },
                },
                'requestState': 'blob-1',
              },
            },
          ];
        }
        // Verify the re-issue carried the responses + echoed state.
        final responses = params['inputResponses'] as Map;
        final name =
            ((responses['ask'] as Map)['content'] as Map)['name'];
        expect(params['requestState'], 'blob-1');
        return [
          {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'resultType': 'complete',
              'content': [
                {'type': 'text', 'text': 'hi $name'},
              ],
            },
          },
        ];
      });

      final client = Client(name: 'c', version: '1.0.0');
      await client.connect(transport, statelessMode: true);
      var elicited = 0;
      client.onElicitationRequest((params) async {
        elicited++;
        return {
          'action': 'accept',
          'content': {'name': 'Zoe'},
        };
      });

      final result = await client.callTool('greet', {});
      expect(elicited, 1);
      expect((result.content.first as TextContent).text, 'hi Zoe');
      // Two tools/call requests were sent (original + re-issue).
      expect(transport.sent.where((m) => m['method'] == 'tools/call').length, 2);
      client.disconnect();
    });

    test('absent resultType is treated as complete (backward compatible)',
        () async {
      final transport = _ScriptedTransport((out) {
        if (out['method'] != 'tools/call') return const [];
        return [
          {
            'jsonrpc': '2.0',
            'id': out['id'],
            'result': {
              // No resultType field at all (older-revision server).
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
            },
          },
        ];
      });
      final client = Client(name: 'c', version: '1.0.0');
      await client.connect(transport, statelessMode: true);
      // No elicitation handler — a missing resultType MUST NOT trigger MRTR.
      final result = await client.callTool('t', {});
      expect((result.content.first as TextContent).text, 'ok');
      client.disconnect();
    });
  });

  group('R2 client — subscriptions/listen consumer', () {
    test('acknowledged filter, stamped notifications, terminal close', () async {
      late int subId;
      final transport = _ScriptedTransport((out) {
        if (out['method'] == 'subscriptions/listen') {
          subId = out['id'] as int;
          return [
            {
              'jsonrpc': '2.0',
              'method': 'notifications/subscriptions/acknowledged',
              'params': {
                'notifications': {'resourcesListChanged': true},
                '_meta': {
                  'io.modelcontextprotocol/subscriptionId': subId,
                },
              },
            },
            {
              'jsonrpc': '2.0',
              'method': 'notifications/resources/list_changed',
              'params': {
                '_meta': {
                  'io.modelcontextprotocol/subscriptionId': subId,
                },
              },
            },
          ];
        }
        if (out['method'] == 'notifications/cancelled') {
          // Terminal SubscriptionsListenResult (response id == subscriptionId).
          return [
            {
              'jsonrpc': '2.0',
              'id': subId,
              'result': {
                'resultType': 'complete',
                '_meta': {
                  'io.modelcontextprotocol/subscriptionId': subId,
                },
              },
            },
          ];
        }
        return const [];
      });

      final client = Client(name: 'c', version: '1.0.0');
      await client.connect(transport, statelessMode: true);

      final received = <SubscriptionNotification>[];
      final sub = await client.listen(
          const SubscriptionFilter(resourcesListChanged: true));
      final done = Completer<void>();
      sub.notifications.listen(received.add, onDone: done.complete);

      final honored = await sub.acknowledged;
      expect(honored.resourcesListChanged, isTrue);

      // Let the scripted list_changed notification arrive.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(received.single.method, 'notifications/resources/list_changed');
      expect(
        McpRequestMeta.readSubscriptionId(received.single.params['_meta']),
        sub.subscriptionId,
      );

      sub.cancel();
      await done.future.timeout(const Duration(seconds: 2));
      client.disconnect();
    });
  });

  group('R2 client — model round-trips', () {
    test('SubscriptionFilter toJson emits only set fields', () {
      const f = SubscriptionFilter(
        toolsListChanged: true,
        resourceSubscriptions: ['file:///a'],
      );
      expect(f.toJson(), {
        'toolsListChanged': true,
        'resourceSubscriptions': ['file:///a'],
      });
    });

    test('InputRequiredResult.fromJson parses requests + state', () {
      final r = InputRequiredResult.fromJson({
        'resultType': 'input_required',
        'inputRequests': {
          'k': {'method': 'roots/list', 'params': {}},
        },
        'requestState': 's',
      });
      expect(r.requestState, 's');
      expect(r.inputRequests['k']!['method'], 'roots/list');
    });

    test('McpResultType.of defaults to complete when absent', () {
      expect(McpResultType.of({'content': []}), McpResultType.complete);
      expect(McpResultType.of({'resultType': 'input_required'}),
          McpResultType.inputRequired);
    });
  });
}
