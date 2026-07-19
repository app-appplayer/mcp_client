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

/// Draft `InputRequiredResult` — the server needs more input before the original
/// request can complete. At least one of [inputRequests] / [requestState] is
/// present; [requestState] is an OPAQUE blob the client MUST NOT interpret and
/// echoes back verbatim on retry.
class InputRequiredResult {
  /// Server-issued requests keyed by a server-assigned identifier. Each value is
  /// a `{ "method": ..., "params": ... }` request object
  /// (`sampling/createMessage` | `roots/list` | `elicitation/create`).
  final Map<String, Map<String, dynamic>> inputRequests;

  /// Opaque state blob echoed back on retry (may be null when only inputs were
  /// requested).
  final String? requestState;

  const InputRequiredResult({
    this.inputRequests = const {},
    this.requestState,
  });

  factory InputRequiredResult.fromJson(Map<String, dynamic> json) {
    final raw = json['inputRequests'];
    final reqs = <String, Map<String, dynamic>>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) reqs[k as String] = Map<String, dynamic>.from(v);
      });
    }
    return InputRequiredResult(
      inputRequests: reqs,
      requestState: json['requestState'] as String?,
    );
  }
}

/// Draft `SubscriptionFilter` — the opt-in set of notification types the client
/// requests on a `subscriptions/listen` stream. The server MUST NOT deliver a
/// type not requested here.
class SubscriptionFilter {
  final bool toolsListChanged;
  final bool promptsListChanged;
  final bool resourcesListChanged;

  /// Resource URIs to receive `notifications/resources/updated` for (replaces
  /// the former `resources/subscribe` RPC).
  final List<String> resourceSubscriptions;

  const SubscriptionFilter({
    this.toolsListChanged = false,
    this.promptsListChanged = false,
    this.resourcesListChanged = false,
    this.resourceSubscriptions = const <String>[],
  });

  factory SubscriptionFilter.fromJson(Map<String, dynamic> json) {
    final subs = json['resourceSubscriptions'];
    return SubscriptionFilter(
      toolsListChanged: json['toolsListChanged'] == true,
      promptsListChanged: json['promptsListChanged'] == true,
      resourcesListChanged: json['resourcesListChanged'] == true,
      resourceSubscriptions: subs is List
          ? subs.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
    );
  }

  /// Emits only the requested fields (booleans only when true, URIs only when
  /// non-empty) — matching the `SubscriptionsListenRequestParams.notifications`
  /// shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (toolsListChanged) 'toolsListChanged': true,
        if (promptsListChanged) 'promptsListChanged': true,
        if (resourcesListChanged) 'resourcesListChanged': true,
        if (resourceSubscriptions.isNotEmpty)
          'resourceSubscriptions': resourceSubscriptions,
      };
}

/// A live 2026-07-28 `subscriptions/listen` subscription handle (SEP-2577).
///
/// Exposes the acknowledged filter, the stream of notifications delivered on it
/// (each stamped with the subscriptionId), and [cancel] to terminate the stream
/// (sends `notifications/cancelled` referencing the subscriptionId).
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
