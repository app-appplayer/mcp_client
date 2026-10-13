/// Coverage for `lib/src/protocol/multi_round_trip.dart` (MRTR + subscription
/// types), gap-filling branches not already exercised by
/// `stateless_mrtr_client_test.dart`.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('McpResultType.of', () {
    test('returns the explicit resultType when present', () {
      expect(McpResultType.of({'resultType': 'input_required'}),
          McpResultType.inputRequired);
      expect(McpResultType.of({'resultType': 'task'}), McpResultType.task);
    });

    test('treats an absent resultType as complete (back-compat)', () {
      expect(McpResultType.of(const {}), McpResultType.complete);
    });

    test('treats a non-string resultType as complete', () {
      expect(McpResultType.of({'resultType': 42}), McpResultType.complete);
    });
  });

  group('InputRequiredResult.fromJson', () {
    test('parses inputRequests and requestState', () {
      final result = InputRequiredResult.fromJson({
        'inputRequests': {
          'req-1': {'method': 'sampling/createMessage', 'params': {}},
        },
        'requestState': 'opaque-blob',
      });
      expect(result.inputRequests!.keys, contains('req-1'));
      expect(result.inputRequests!['req-1'], isA<CreateMessageRequest>());
      expect(result.requestState, 'opaque-blob');
    });

    test('tolerates malformed / absent inputRequests', () {
      final result = InputRequiredResult.fromJson(const {});
      expect(result.inputRequests, isNull);
      expect(result.requestState, isNull);
    });

    test('a malformed entry is reported and kept, not dropped', () {
      final result = InputRequiredResult.fromJson({
        'resultType': 'input_required',
        'inputRequests': {'req-1': 'not-a-map', 'req-2': {'method': 'x'}},
      });
      expect(result.check(), isNotEmpty);
      expect((result.toJson()['inputRequests'] as Map).keys, ['req-1', 'req-2']);
    });
  });

  group('SubscriptionFilter', () {
    test('fromJson parses resourceSubscriptions list', () {
      final filter = SubscriptionFilter.fromJson({
        'toolsListChanged': true,
        'promptsListChanged': true,
        'resourcesListChanged': true,
        'resourceSubscriptions': ['file:///a', 'file:///b'],
      });
      expect(filter.toolsListChanged, isTrue);
      expect(filter.promptsListChanged, isTrue);
      expect(filter.resourcesListChanged, isTrue);
      expect(filter.resourceSubscriptions, ['file:///a', 'file:///b']);
    });

    test('absent fields read as absent; a wrong type is reported', () {
      final filter = SubscriptionFilter.fromJson(const {});
      expect(filter.toolsListChanged, isNull);
      expect(filter.resourceSubscriptions, isNull);

      final filter2 =
          SubscriptionFilter.fromJson({'resourceSubscriptions': 'not-a-list'});
      expect(filter2.check(), isNotEmpty);
    });

    test('toJson emits only truthy/non-empty fields', () {
      final filter = SubscriptionFilter(
        toolsListChanged: true,
        resourceSubscriptions: ['file:///a'],
      );
      final json = filter.toJson();
      expect(json['toolsListChanged'], isTrue);
      expect(json.containsKey('promptsListChanged'), isFalse);
      expect(json.containsKey('resourcesListChanged'), isFalse);
      expect(json['resourceSubscriptions'], ['file:///a']);
    });

    test('toJson is empty for an all-default filter', () {
      final filter = SubscriptionFilter();
      expect(filter.toJson(), <String, dynamic>{});
    });
  });

  group('Subscription / SubscriptionNotification', () {
    test('holds the subscriptionId, acknowledged filter, and stream', () async {
      final controller = StreamController<SubscriptionNotification>();
      var cancelled = false;
      final subscription = Subscription(
        subscriptionId: 7,
        acknowledged: Future.value(
          SubscriptionFilter(toolsListChanged: true),
        ),
        notifications: controller.stream,
        cancel: () => cancelled = true,
      );

      expect(subscription.subscriptionId, 7);
      final ack = await subscription.acknowledged;
      expect(ack.toolsListChanged, isTrue);

      const notification =
          SubscriptionNotification(method: 'notifications/x', params: {'a': 1});
      expect(notification.method, 'notifications/x');
      expect(notification.params, {'a': 1});

      controller.add(notification);
      final received = await subscription.notifications.first;
      expect(received.method, 'notifications/x');

      subscription.cancel();
      expect(cancelled, isTrue);
      await controller.close();
    });
  });
}
