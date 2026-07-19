/// Protocol constants and utilities for MCP
library;

/// MCP protocol versions and constants
class McpProtocol {
  /// Protocol version 2024-11-05
  static const String v2024_11_05 = "2024-11-05";

  /// Protocol version 2025-03-26
  static const String v2025_03_26 = "2025-03-26";

  /// Protocol version 2025-06-18 — adds elicitation, structured tool
  /// output, resource_link, OAuth Resource Server, MCP-Protocol-Version
  /// header. Removes JSON-RPC batching.
  static const String v2025_06_18 = "2025-06-18";

  /// Protocol version 2025-11-25 — adds icons, sampling tool calling
  /// (`tools` / `toolChoice`), URL-mode elicitation, OIDC Discovery,
  /// Client ID Metadata Documents, default values in elicitation
  /// primitives.
  static const String v2025_11_25 = "2025-11-25";

  /// Protocol version 2026-07-28 — BREAKING: stateless core (removes the
  /// `initialize`/`initialized` handshake and `Mcp-Session-Id`; client
  /// info/caps ride `_meta` on every request; `server/discover` fetches
  /// caps on demand), Extensions framework, Tasks extension, auth
  /// hardening, deprecations (Roots/Sampling/Logging). Adopted as an
  /// additive, version-gated parallel path — the handshake path stays for
  /// ≤2025-11-25 peers. NOT yet in [supportedVersions] until the stateless
  /// request path lands (opt-in via a stateless connection mode).
  static const String v2026_07_28 = "2026-07-28";

  /// Whether the [version] uses the stateless core (no handshake/session):
  /// client info/caps in `_meta` per request, `server/discover` for caps,
  /// `MCP-Protocol-Version` as the sole version signal. Introduced
  /// 2026-07-28. See `docs/STATELESS-COEXISTENCE-DESIGN.md`.
  static bool isStateless(String version) => version == v2026_07_28;

  /// Supported protocol versions in order of preference (newest first).
  ///
  /// `v2026_07_28` is intentionally NOT listed yet: it is declared but its
  /// stateless request path is not implemented, so the server must not
  /// advertise it during handshake negotiation until that lands.
  static const List<String> supportedVersions = [
    v2025_11_25,
    v2025_06_18,
    v2025_03_26,
    v2024_11_05,
  ];

  /// Default protocol version (latest supported).
  static const String defaultVersion = v2025_11_25;

  /// Whether the negotiated [version] supports JSON-RPC batching.
  /// Removed in 2025-06-18.
  static bool supportsBatching(String version) =>
      version == v2024_11_05 || version == v2025_03_26;

  /// Whether the negotiated [version] understands `elicitation/create`
  /// (introduced 2025-06-18).
  static bool supportsElicitation(String version) =>
      version == v2025_06_18 || version == v2025_11_25;

  /// Whether the negotiated [version] requires the
  /// `MCP-Protocol-Version` HTTP header on every post-handshake request
  /// (mandatory from 2025-06-18).
  static bool requiresProtocolHeader(String version) =>
      version == v2025_06_18 || version == v2025_11_25;

  /// Whether the negotiated [version] understands `icons`, sampling
  /// `tools` / `toolChoice`, URL-mode elicitation, multi-select /
  /// default-valued elicitation primitives, and `Implementation.description`
  /// (all introduced in 2025-11-25). Mirrors the server package's
  /// `McpProtocol.supportsIconsAndSamplingTools` predicate so both sides
  /// gate the same behavior on the same negotiated revision.
  static bool supportsIconsAndSamplingTools(String version) =>
      version == v2025_11_25;

  /// Whether the negotiated [version] understands sampling tool calling —
  /// the `tools` / `toolChoice` request fields and tool-call results on
  /// `sampling/createMessage` (SEP: sampling with tools, 2025-11-25). Alias
  /// of [supportsIconsAndSamplingTools] scoped to the sampling surface.
  static bool supportsSamplingTools(String version) =>
      supportsIconsAndSamplingTools(version);

  /// Whether the negotiated [version] understands URL-mode elicitation
  /// (`mode: "url"`, SEP-1036), multi-select enums (SEP-1330), and default
  /// values in elicitation primitives (SEP-1034). All landed in 2025-11-25.
  static bool supportsUrlElicitation(String version) =>
      version == v2025_11_25;

  /// Whether the negotiated [version] carries `Implementation.description`
  /// on `clientInfo` / `serverInfo` (2025-11-25). Older peers ignore an
  /// emitted `description`, so emission is additive; this predicate exists
  /// so callers may suppress it for strict older-revision fixtures.
  static bool supportsImplementationDescription(String version) =>
      version == v2025_11_25;

  /// Canonical JSON Schema dialect for tool `inputSchema` / `outputSchema`
  /// and elicitation `requestedSchema` when the negotiated revision is
  /// 2025-11-25+ (SEP-1613). A schema that omits `$schema` is interpreted
  /// against this dialect; existing schemas that declare their own
  /// `$schema` are left untouched.
  static const String jsonSchemaDialect2020_12 =
      "https://json-schema.org/draft/2020-12/schema";

  /// The default JSON Schema dialect a peer should assume for schemas that
  /// omit `$schema` under the negotiated [version]. 2025-11-25 pins
  /// 2020-12 (SEP-1613); earlier revisions left the dialect unspecified
  /// (returns null — callers must not stamp a dialect for those peers).
  static String? defaultSchemaDialect(String version) =>
      version == v2025_11_25 ? jsonSchemaDialect2020_12 : null;

  /// Return a copy of [schema] annotated with the 2020-12 `$schema`
  /// dialect when (a) the negotiated [version] pins a default dialect and
  /// (b) the schema does not already declare its own `$schema`. Free-form
  /// schemas that already carry a `$schema` — or any schema under an older
  /// negotiated revision — are returned unchanged. Non-mutating: the input
  /// map is never modified.
  static Map<String, dynamic> schemaWithDefaultDialect(
    Map<String, dynamic> schema,
    String version,
  ) {
    final dialect = defaultSchemaDialect(version);
    if (dialect == null || schema.containsKey(r'$schema')) {
      return schema;
    }
    return <String, dynamic>{r'$schema': dialect, ...schema};
  }

  /// JSON-RPC version
  static const String jsonRpcVersion = "2.0";

  /// Standard MCP methods
  static const String methodInitialize = "initialize";
  static const String methodInitialized = "notifications/initialized";
  static const String methodShutdown = "shutdown";
  static const String methodListTools = "tools/list";
  static const String methodCallTool = "tools/call";
  static const String methodCancelTool = "tools/cancel";
  static const String methodListResources = "resources/list";
  static const String methodReadResource = "resources/read";
  static const String methodSubscribeResource = "resources/subscribe";
  static const String methodUnsubscribeResource = "resources/unsubscribe";
  static const String methodListResourceTemplates = "resources/templates/list";
  static const String methodListPrompts = "prompts/list";
  static const String methodGetPrompt = "prompts/get";
  static const String methodComplete = "completion/complete";
  static const String methodListRoots = "roots/list";

  /// 2025-03-26 New methods
  static const String methodCapabilitiesUpdate = "capabilities/update";

  /// Notifications
  static const String methodProgress = "notifications/progress";
  static const String methodCancelled = "notifications/cancelled";
  static const String methodResourceUpdated = "notifications/resources/updated";
  static const String methodResourceListChanged =
      "notifications/resources/list_changed";
  static const String methodToolListChanged =
      "notifications/tools/list_changed";
  static const String methodPromptListChanged =
      "notifications/prompts/list_changed";
  static const String methodRootListChanged =
      "notifications/roots/list_changed";
  static const String methodLog = "notifications/message";
  static const String methodSetLevel = "logging/setLevel";

  /// Authorization methods (2025-03-26)
  static const String methodAuthorize = "auth/authorize";
  static const String methodToken = "auth/token";
  static const String methodRevoke = "auth/revoke";
  static const String methodRefresh = "auth/refresh";

  /// Progress token types
  static const String progressTokenString = "string";
  static const String progressTokenNumber = "number";

  /// Standard error codes
  static const int errorParse = -32700;
  static const int errorInvalidRequest = -32600;
  static const int errorMethodNotFound = -32601;
  static const int errorInvalidParams = -32602;
  static const int errorInternal = -32603;

  /// MCP-specific error codes
  static const int errorResourceNotFound = -32001;
  static const int errorResourceAccessDenied = -32002;
  static const int errorToolNotFound = -32003;
  static const int errorToolExecutionFailed = -32004;
  static const int errorPromptNotFound = -32005;
  static const int errorProtocolError = -32006;

  /// Check if a version is supported
  static bool isVersionSupported(String version) {
    return supportedVersions.contains(version);
  }

  /// Get the best common version from client and server versions
  static String? negotiateVersion(
    List<String> clientVersions,
    List<String> serverVersions,
  ) {
    for (final version in clientVersions) {
      if (serverVersions.contains(version) && isVersionSupported(version)) {
        return version;
      }
    }
    return null;
  }
}

/// Protocol capabilities
class ProtocolCapabilities {
  final bool experimental;
  final bool tools;
  final bool resources;
  final bool prompts;
  final bool logging;

  const ProtocolCapabilities({
    this.experimental = false,
    this.tools = true,
    this.resources = true,
    this.prompts = true,
    this.logging = true,
  });

  Map<String, dynamic> toJson() => {
    if (experimental) 'experimental': experimental,
    if (tools) 'tools': tools,
    if (resources) 'resources': resources,
    if (prompts) 'prompts': prompts,
    if (logging) 'logging': logging,
  };

  factory ProtocolCapabilities.fromJson(Map<String, dynamic> json) {
    return ProtocolCapabilities(
      experimental: json['experimental'] ?? false,
      tools: json['tools'] ?? true,
      resources: json['resources'] ?? true,
      prompts: json['prompts'] ?? true,
      logging: json['logging'] ?? true,
    );
  }
}
