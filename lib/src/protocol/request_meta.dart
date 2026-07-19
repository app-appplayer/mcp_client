/// Reverse-DNS `_meta` keys and typed read/write helpers for the 2026-07-28
/// stateless core (SEP-2577).
///
/// On the stateless path there is no `initialize` handshake, so the client
/// attaches its identity and per-request capabilities to the `_meta` object
/// of EVERY request under the reserved `io.modelcontextprotocol/*` prefix
/// (the second label `modelcontextprotocol` is reserved for MCP use). The
/// server reads them per request and MUST NOT infer capabilities from any
/// prior request.
///
/// These are additive helpers layered on top of the existing `_meta`
/// passthrough — they neither consume nor rewrite unknown `_meta` keys, so a
/// legacy (handshake) request that never sets them is unaffected.
///
/// Draft schema (`schema/draft/schema.ts`, `RequestMetaObject` /
/// `ResultMetaObject`) is the source of truth for the key names and value
/// shapes; see `mcp_server/docs/STATELESS-COEXISTENCE-DESIGN.md` §3.2.
library;

/// Reverse-DNS `_meta` key constants and typed accessors for the stateless
/// core. All keys sit under the reserved `io.modelcontextprotocol/` prefix.
class McpRequestMeta {
  McpRequestMeta._();

  /// `RequestMetaObject."io.modelcontextprotocol/protocolVersion"` — the MCP
  /// protocol version for this request (REQUIRED on the stateless path). For
  /// HTTP it MUST equal the `MCP-Protocol-Version` header.
  static const String keyProtocolVersion =
      'io.modelcontextprotocol/protocolVersion';

  /// `RequestMetaObject."io.modelcontextprotocol/clientInfo"` — self-reported
  /// client software identity (name+version). Display/logging only.
  static const String keyClientInfo = 'io.modelcontextprotocol/clientInfo';

  /// `RequestMetaObject."io.modelcontextprotocol/clientCapabilities"` — the
  /// client's capabilities FOR THIS REQUEST (REQUIRED on the stateless path).
  /// An empty object means no optional capabilities.
  static const String keyClientCapabilities =
      'io.modelcontextprotocol/clientCapabilities';

  /// `RequestMetaObject."io.modelcontextprotocol/logLevel"` — the per-request
  /// desired log level (replaces the `logging/setLevel` RPC). Optional.
  static const String keyLogLevel = 'io.modelcontextprotocol/logLevel';

  /// `ResultMetaObject."io.modelcontextprotocol/serverInfo"` — self-reported
  /// server software identity carried on a response `_meta`.
  static const String keyServerInfo = 'io.modelcontextprotocol/serverInfo';

  /// Build a request `_meta` object carrying the reverse-DNS stateless keys.
  ///
  /// [protocolVersion] and [clientCapabilities] are required by the schema;
  /// [clientInfo] and [logLevel] are optional. [extra] is merged first so the
  /// reserved keys always win. Returns a fresh map (never mutates inputs).
  static Map<String, dynamic> build({
    required String protocolVersion,
    required Map<String, dynamic> clientCapabilities,
    Map<String, dynamic>? clientInfo,
    String? logLevel,
    Map<String, dynamic>? extra,
  }) {
    return <String, dynamic>{
      if (extra != null) ...extra,
      keyProtocolVersion: protocolVersion,
      keyClientCapabilities: clientCapabilities,
      if (clientInfo != null) keyClientInfo: clientInfo,
      if (logLevel != null) keyLogLevel: logLevel,
    };
  }

  /// Read `io.modelcontextprotocol/protocolVersion` from a request `_meta`.
  static String? readProtocolVersion(Object? meta) {
    final v = _asMap(meta)?[keyProtocolVersion];
    return v is String ? v : null;
  }

  /// Read `io.modelcontextprotocol/clientInfo` from a request `_meta`.
  static Map<String, dynamic>? readClientInfo(Object? meta) =>
      _asStringMap(_asMap(meta)?[keyClientInfo]);

  /// Read `io.modelcontextprotocol/clientCapabilities` from a request
  /// `_meta`. Returns `null` when absent (distinct from an empty object).
  static Map<String, dynamic>? readClientCapabilities(Object? meta) =>
      _asStringMap(_asMap(meta)?[keyClientCapabilities]);

  /// Read `io.modelcontextprotocol/logLevel` from a request `_meta`.
  static String? readLogLevel(Object? meta) {
    final v = _asMap(meta)?[keyLogLevel];
    return v is String ? v : null;
  }

  /// Build a result `_meta` object carrying `serverInfo`, merging [extra]
  /// first so the reserved key wins. Returns a fresh map.
  static Map<String, dynamic> buildResult({
    required Map<String, dynamic> serverInfo,
    Map<String, dynamic>? extra,
  }) {
    return <String, dynamic>{
      if (extra != null) ...extra,
      keyServerInfo: serverInfo,
    };
  }

  /// Read `io.modelcontextprotocol/serverInfo` from a result `_meta`.
  static Map<String, dynamic>? readServerInfo(Object? meta) =>
      _asStringMap(_asMap(meta)?[keyServerInfo]);

  /// `NotificationMetaObject."io.modelcontextprotocol/subscriptionId"` — the
  /// JSON-RPC id of the `subscriptions/listen` request whose stream carried this
  /// notification (also on `SubscriptionsListenResult._meta`). Absent on
  /// non-subscription notifications.
  static const String keySubscriptionId =
      'io.modelcontextprotocol/subscriptionId';

  /// Read `io.modelcontextprotocol/subscriptionId` from a notification `_meta`.
  static Object? readSubscriptionId(Object? meta) =>
      _asMap(meta)?[keySubscriptionId];

  static Map? _asMap(Object? v) => v is Map ? v : null;

  static Map<String, dynamic>? _asStringMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;
}
