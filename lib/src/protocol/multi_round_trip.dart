/// 2026-07-28 Multi-Round-Trip (MRTR) + subscription types — client side
/// (SEP-2577).
///
/// On the stateless path the server answers a request needing input with an
/// [InputRequiredResult] (result kind `input_required`) instead of pushing a
/// server→client request. The client fulfills the embedded input requests
/// (sampling / roots / elicitation) with its registered handlers, then re-issues
/// the ORIGINAL request carrying the matching input responses + the opaque
/// `requestState`, looping until a terminal (`complete`) result.
///
/// Types trace to the draft schema (`schema/draft/schema.ts`): `ResultType`,
/// `InputRequiredResult`, `InputResponseRequestParams`, `SubscriptionFilter`.
/// See `mcp_server/docs/STATELESS-COEXISTENCE-DESIGN.md` §3.3/§3.4. Everything
/// here is additive and only exercised on the stateless (2026-07-28) path.
library;

import '../schema/schema.g.dart';

/// Draft `ResultType` discriminator values (`schema.ts` `ResultType`).
///
/// A 2026-07-28 result always carries `resultType`. A result from an earlier
/// revision omits it; the client MUST treat the absent value as [complete].
class McpResultType {
  McpResultType._();

  /// The wire key on a `Result` object.
  static const String key = 'resultType';

  /// `"complete"` — final content; parse the result normally.
  static const String complete = 'complete';

  /// `"input_required"` — the result is an [InputRequiredResult].
  static const String inputRequired = 'input_required';

  /// `"task"` — the result is a `CreateTaskResult` (`Result & Task`); the
  /// server processes the request asynchronously and the client tracks it via
  /// `tasks/get` / `tasks/update` / `tasks/cancel` (Tasks extension, 2026-07-28).
  static const String task = 'task';

  /// The result type of [result], treating an absent field as [complete]
  /// (backward compatibility with earlier revisions).
  static String of(Map<String, dynamic> result) {
    final v = result[key];
    return v is String ? v : complete;
  }
}

class Subscription {
  /// The subscriptionId (== the JSON-RPC id of the `subscriptions/listen`
  /// request that opened this stream).
  final int subscriptionId;

  /// The subset of the requested filter the server agreed to honor (from the
  /// `notifications/subscriptions/acknowledged` message).
  final Future<SubscriptionFilter> acknowledged;

  /// Notifications delivered on this stream (`method` + `params`). Terminates
  /// when the server closes the subscription.
  final Stream<SubscriptionNotification> notifications;

  /// Terminates the subscription (`notifications/cancelled`).
  final void Function() cancel;

  const Subscription({
    required this.subscriptionId,
    required this.acknowledged,
    required this.notifications,
    required this.cancel,
  });
}

/// A single notification delivered on a [Subscription] stream.
class SubscriptionNotification {
  final String method;
  final Map<String, dynamic> params;

  const SubscriptionNotification({required this.method, required this.params});
}
