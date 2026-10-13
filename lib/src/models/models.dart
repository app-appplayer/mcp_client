import 'package:meta/meta.dart';

import '../schema/schema.g.dart' as schema;
import '../schema/schema.g.dart';

// Protocol types: generated from the official MCP schema (every supported
// revision). `ClientCapabilities` / `ServerCapabilities` stay this package's
// own classes (boolean API, complete field set, the received JSON kept in
// `raw`); the generated ones are reachable as `ClientCapabilitiesSchema` /
// `ServerCapabilitiesSchema`.
export '../schema/schema.g.dart' hide ClientCapabilities, ServerCapabilities;

/// The generated `ClientCapabilities` (wire form, every field).
typedef ClientCapabilitiesSchema = schema.ClientCapabilities;

/// The generated `ServerCapabilities` (wire form, every field).
typedef ServerCapabilitiesSchema = schema.ServerCapabilities;

/// Log levels, in the order the protocol ranks them.
enum McpLogLevel {
  debug,
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency;

  /// The protocol value.
  LoggingLevel get level => LoggingLevel.of(name);
}

// --- 2.x names -------------------------------------------------------------

/// 2.x name of [ContentBlock].
@Deprecated('Use ContentBlock')
typedef Content = ContentBlock;

/// 2.x name of [ResourceLink].
@Deprecated('Use ResourceLink')
typedef ResourceLinkContent = ResourceLink;

/// 2.x name of [CompleteResult].
@Deprecated('Use CompleteResult')
typedef CompletionResult = CompleteResult;

/// 2.x name of [Implementation] for a server.
typedef ServerInfo = Implementation;

/// 2.x name of [Implementation] for a client.
typedef ClientInfo = Implementation;

/// 2.x's `ResourceContentInfo`: resource contents with either [text] or
/// [blob] (base64). A type as well as a constructor, so 2.x code that names
/// it (`List<ResourceContentInfo>`) keeps compiling; the value is the
/// [TextResourceContents] or [BlobResourceContents] itself.
extension type ResourceContentInfo._(ResourceContents _contents) implements ResourceContents {
  ResourceContentInfo({
    required String uri,
    String? mimeType,
    String? text,
    String? blob,
    Map<String, Object?>? meta,
  }) : _contents = blob != null
            ? BlobResourceContents(uri: uri, mimeType: mimeType, blob: blob, meta: meta)
            : text != null
                ? TextResourceContents(uri: uri, mimeType: mimeType, text: text, meta: meta)
                // Neither, as 2.x allowed: kept as given, so `text` stays null
                // (not an invented empty string).
                : ResourceContents.fromJson({
                    'uri': uri,
                    if (mimeType != null) 'mimeType': mimeType,
                    if (meta != null) '_meta': meta,
                  });

  /// Any resource contents viewed under the 2.x name.
  ResourceContentInfo.of(ResourceContents contents) : _contents = contents;

  /// Reads resource contents JSON (text or blob).
  ResourceContentInfo.fromJson(Map<String, dynamic> json)
      : _contents = ResourceContents.fromJson(Map<String, Object?>.from(json));
}

/// 2.x's `ResourceContent`: an embedded resource content block. A type as
/// well as a constructor; the value is the [EmbeddedResource] itself, read
/// through the 2.x members ([uri], [text], [blob], [mimeType] and
/// [annotations] as a map).
extension type ResourceContent._(EmbeddedResource _block) implements EmbeddedResource {
  /// [annotations] is the 2.x map or an [Annotations].
  ResourceContent({
    required String uri,
    String? mimeType,
    String? text,
    String? blob,
    Object? annotations,
    Map<String, Object?>? meta,
  }) : _block = EmbeddedResource(
          resource: ResourceContentInfo(uri: uri, mimeType: mimeType, text: text, blob: blob),
          annotations: annotations is Map
              ? Annotations.fromJson(Map<String, Object?>.from(annotations))
              : annotations as Annotations?,
          meta: meta,
        );

  /// Any embedded resource viewed under the 2.x name.
  ResourceContent.of(EmbeddedResource block) : _block = block;

  /// Reads an embedded resource content block; the flat form 2.x also read
  /// (`{"type": "resource", "uri": …, "text": …}`) is nested as the
  /// specification has it.
  ResourceContent.fromJson(Map<String, dynamic> json)
      : _block = EmbeddedResource.fromJson(json['resource'] is Map
            ? Map<String, Object?>.from(json)
            : {
                'type': 'resource',
                'resource': {
                  for (final k in const ['uri', 'mimeType', 'text', 'blob', '_meta'])
                    if (json.containsKey(k)) k: json[k],
                },
                if (json.containsKey('annotations')) 'annotations': json['annotations'],
              });

  /// The resource's URI.
  String get uri => _block.resource.uri;

  /// The resource's MIME type, when given.
  String? get mimeType => _block.resource.mimeType;

  /// The text, for text contents.
  String? get text => _block.resource.text;

  /// The base64 data, for binary contents.
  String? get blob => _block.resource.blob;

  /// The annotations as a map (2.x).
  Map<String, dynamic>? get annotations {
    final a = _block.annotations;
    return a == null ? null : Map<String, dynamic>.from(a.toJson());
  }
}

/// 2.x's `Message`: a prompt message. [role] is a [Role] or its value
/// (`'user'`, `'assistant'`). A type as well as a constructor; the value is
/// the [PromptMessage] itself.
extension type Message._(PromptMessage _message) implements PromptMessage {
  Message({required Object role, required ContentBlock content})
      : _message = PromptMessage(role: role is Role ? role : Role.of('$role'), content: content);

  /// Any prompt message viewed under the 2.x name.
  Message.of(PromptMessage message) : _message = message;

  /// Reads a prompt message.
  Message.fromJson(Map<String, dynamic> json)
      : _message = PromptMessage.fromJson(Map<String, Object?>.from(json));
}

/// Error class for MCP-related errors
@immutable
class McpError implements Exception {
  final String message;
  final int? code;

  /// The error's `data` member when it came from the server.
  final Object? data;

  const McpError(this.message, {this.code, this.data});

  @override
  String toString() => 'McpError ${code != null ? '($code)' : ''}: $message';
}

/// JSON-RPC message
@immutable
class JsonRpcMessage {
  final String jsonrpc;
  final dynamic id;
  final String? method;
  final Map<String, dynamic>? params;
  final dynamic result;
  final Map<String, dynamic>? error;

  bool get isNotification => id == null && method != null;
  bool get isRequest => id != null && method != null;
  bool get isResponse => id != null && (result != null || error != null);

  const JsonRpcMessage({
    required this.jsonrpc,
    this.id,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  factory JsonRpcMessage.fromJson(Map<String, dynamic> json) {
    // Ensure params is properly typed as Map<String, dynamic>
    Map<String, dynamic>? params;
    if (json['params'] != null) {
      if (json['params'] is Map) {
        params =
            (json['params'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      } else {
        throw FormatException(
          'Invalid params: expected a Map, got ${json['params'].runtimeType}',
        );
      }
    }

    // Ensure error is properly typed as Map<String, dynamic>
    Map<String, dynamic>? error;
    if (json['error'] != null) {
      if (json['error'] is Map) {
        error =
            (json['error'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      } else {
        throw FormatException(
          'Invalid error: expected a Map, got ${json['error'].runtimeType}',
        );
      }
    }

    return JsonRpcMessage(
      jsonrpc: json['jsonrpc'] as String,
      id: json['id'],
      method: json['method'] as String?,
      params: params,
      result: json['result'],
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'jsonrpc': jsonrpc};
    if (id != null) json['id'] = id;
    if (method != null) json['method'] = method!;
    if (params != null) json['params'] = params!;
    if (result != null) json['result'] = result;
    if (error != null) json['error'] = error!;
    return json;
  }
}

/// Server health information
@immutable
class ServerHealth {
  /// Health status (e.g., 'healthy', 'degraded', 'unhealthy')
  final String status;

  /// Server version
  final String? version;

  /// Number of active connections
  final int connections;

  /// Whether the server is running
  final bool isRunning;

  /// Number of connected client sessions
  final int connectedSessions;

  /// Number of registered tools
  final int registeredTools;

  /// Number of registered resources
  final int registeredResources;

  /// Number of registered prompts
  final int registeredPrompts;

  /// When the server started
  final DateTime startTime;

  /// How long the server has been running
  final Duration uptime;

  /// Detailed performance metrics
  final Map<String, dynamic> metrics;

  const ServerHealth({
    this.status = 'healthy',
    this.version,
    this.connections = 0,
    required this.isRunning,
    required this.connectedSessions,
    required this.registeredTools,
    required this.registeredResources,
    required this.registeredPrompts,
    required this.startTime,
    required this.uptime,
    required this.metrics,
  });

  factory ServerHealth.fromJson(Map<String, dynamic> json) {
    return ServerHealth(
      status: json['status'] as String? ?? 'healthy',
      version: json['version'] as String?,
      connections: json['connections'] as int? ?? 0,
      isRunning: json['isRunning'] as bool? ?? true,
      connectedSessions: json['connectedSessions'] as int? ?? 0,
      registeredTools: json['registeredTools'] as int? ?? 0,
      registeredResources: json['registeredResources'] as int? ?? 0,
      registeredPrompts: json['registeredPrompts'] as int? ?? 0,
      startTime:
          json['startTime'] != null
              ? DateTime.parse(json['startTime'] as String)
              : DateTime.now(),
      uptime:
          json['uptimeSeconds'] != null
              ? Duration(seconds: json['uptimeSeconds'] as int)
              : Duration.zero,
      metrics: json['metrics'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isRunning': isRunning,
      'connectedSessions': connectedSessions,
      'registeredTools': registeredTools,
      'registeredResources': registeredResources,
      'registeredPrompts': registeredPrompts,
      'startTime': startTime.toIso8601String(),
      'uptimeSeconds': uptime.inSeconds,
      'metrics': metrics,
    };
  }
}

/// Pending operation for cancellation support
class PendingOperation {
  /// Unique identifier for this operation
  final String id;

  /// Session ID where this operation is running
  final String sessionId;

  /// Type of the operation (e.g., "tool:calculator")
  final String type;

  /// When the operation was created
  final DateTime createdAt;

  /// Optional ID of the request that initiated this operation
  final String? requestId;

  /// Whether this operation has been cancelled
  bool isCancelled = false;

  PendingOperation({
    required this.id,
    required this.sessionId,
    required this.type,
    required this.createdAt,
    this.requestId,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sessionId': sessionId,
      'type': type,
      'createdAt': createdAt.toIso8601String(),
      'isCancelled': isCancelled,
      if (requestId != null) 'requestId': requestId,
    };
  }

  factory PendingOperation.fromJson(Map<String, dynamic> json) {
    final operation = PendingOperation(
      id: json['id'] as String,
      sessionId: json['sessionId'] as String,
      type: json['type'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      requestId: json['requestId'] as String?,
    );
    operation.isCancelled = json['isCancelled'] as bool? ?? false;
    return operation;
  }
}

/// Progress update for long-running operations
@immutable
class ProgressUpdate {
  /// ID of the request this progress relates to
  final String requestId;

  /// Progress value between 0.0 and 1.0
  final double progress;

  /// Optional message describing the current status
  final String message;

  const ProgressUpdate({
    required this.requestId,
    required this.progress,
    required this.message,
  });

  factory ProgressUpdate.fromJson(Map<String, dynamic> json) {
    return ProgressUpdate(
      requestId: json['requestId'] as String,
      progress: (json['progress'] as num).toDouble(),
      message: json['message'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {'requestId': requestId, 'progress': progress, 'message': message};
  }
}

/// Cached resource item for performance optimization
@immutable
class CachedResource {
  /// URI of the cached resource
  final String uri;

  /// Content of the resource
  final ReadResourceResult content;

  /// When the resource was cached
  final DateTime cachedAt;

  /// How long the cache should be valid
  final Duration maxAge;

  const CachedResource({
    required this.uri,
    required this.content,
    required this.cachedAt,
    required this.maxAge,
  });

  /// Check if the cache entry has expired
  bool get isExpired {
    final now = DateTime.now();
    final expiresAt = cachedAt.add(maxAge);
    return now.isAfter(expiresAt);
  }

  Map<String, dynamic> toJson() {
    return {
      'uri': uri,
      'content': content.toJson(),
      'cachedAt': cachedAt.toIso8601String(),
      'maxAgeSeconds': maxAge.inSeconds,
    };
  }
}

/// Server information (2025-03-26 compliant)
/// What this client supports, as it advertises it.
///
/// Boolean flags for each capability plus every sub-field the protocol
/// defines. [toJson] writes only what is set.
@immutable
class ClientCapabilities {
  const ClientCapabilities({
    this.roots = false,
    this.rootsListChanged = false,
    this.sampling = false,
    this.samplingContext = false,
    this.samplingTools = false,
    this.elicitation = false,
    this.elicitationForm = false,
    this.elicitationUrl = false,
    this.tasks,
    this.experimental,
    this.extensions,
    this.raw,
  });

  /// `roots`: the server may call `roots/list`.
  final bool roots;

  /// `roots.listChanged`.
  final bool rootsListChanged;

  /// `sampling`: the server may call `sampling/createMessage`.
  final bool sampling;

  /// `sampling.context` (2025-11-25): context inclusion supported.
  final bool samplingContext;

  /// `sampling.tools` (2025-11-25): tool use in sampling supported.
  final bool samplingTools;

  /// `elicitation`: the server may call `elicitation/create`.
  final bool elicitation;

  /// `elicitation.form` (2025-11-25).
  final bool elicitationForm;

  /// `elicitation.url` (2025-11-25).
  final bool elicitationUrl;

  /// `tasks` (2025-11-25), as the protocol writes it.
  final Map<String, dynamic>? tasks;

  /// `experimental`: non-standard capabilities.
  final Map<String, Map<String, dynamic>>? experimental;

  /// `extensions` (2026-07-28): reverse-DNS id -> settings.
  final Map<String, Map<String, dynamic>>? extensions;

  /// The capabilities as received (every field, typed), when parsed. Its
  /// sub-objects and any field this class does not name are written back by
  /// [toJson].
  final ClientCapabilitiesSchema? raw;

  /// Whether this set advertises the extension [id].
  bool hasExtension(String id) => extensions?.containsKey(id) ?? false;

  /// Whether sampling is declared (any sampling flag declares it).
  bool get samplingDeclared => sampling || samplingContext || samplingTools;

  /// Whether elicitation is declared (any elicitation flag declares it).
  bool get elicitationDeclared => elicitation || elicitationForm || elicitationUrl;

  /// Whether roots are declared.
  bool get rootsDeclared => roots || rootsListChanged;

  Map<String, dynamic> toJson() {
    final received = raw?.toJson() ?? const <String, Object?>{};
    // What was received under [capability].[sub], when it is declared.
    Map<String, dynamic> part(String capability, String sub) {
      final c = received[capability];
      final v = c is Map ? c[sub] : null;
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    }

    const named = {'roots', 'sampling', 'elicitation', 'tasks', 'experimental', 'extensions'};
    return {
      for (final e in received.entries)
        if (!named.contains(e.key)) e.key: e.value,
      if (rootsDeclared) 'roots': {if (rootsListChanged) 'listChanged': true},
      if (samplingDeclared)
        'sampling': {
          if (samplingContext) 'context': part('sampling', 'context'),
          if (samplingTools) 'tools': part('sampling', 'tools'),
        },
      if (elicitationDeclared)
        'elicitation': {
          if (elicitationForm) 'form': part('elicitation', 'form'),
          if (elicitationUrl) 'url': part('elicitation', 'url'),
        },
      if (tasks != null) 'tasks': tasks,
      if (experimental != null && experimental!.isNotEmpty) 'experimental': experimental,
      if (extensions != null && extensions!.isNotEmpty) 'extensions': extensions,
    };
  }

  factory ClientCapabilities.fromJson(Map<String, dynamic> json) {
    final c = schema.ClientCapabilities.fromJson(json);
    return ClientCapabilities(
      roots: c.roots != null,
      rootsListChanged: c.roots?.listChanged ?? false,
      sampling: c.sampling != null,
      samplingContext: c.sampling?.context != null,
      samplingTools: c.sampling?.tools != null,
      elicitation: c.elicitation != null,
      elicitationForm: c.elicitation?.form != null,
      elicitationUrl: c.elicitation?.url != null,
      tasks: c.has('tasks') ? Map<String, dynamic>.from(c['tasks'] as Map) : null,
      experimental: c.experimental,
      extensions: c.extensions,
      raw: c,
    );
  }
}

/// What a server supports, as it advertised it.
///
/// Boolean flags for each capability and sub-field, plus [raw]: the JSON
/// exactly as received, so a field this class does not name (a newer
/// revision's, an extension's) is still there.
@immutable
class ServerCapabilities {
  const ServerCapabilities({
    this.tools = false,
    this.toolsListChanged = false,
    this.resources = false,
    this.resourcesSubscribe = false,
    this.resourcesListChanged = false,
    this.prompts = false,
    this.promptsListChanged = false,
    this.logging = false,
    this.completions = false,
    this.tasks,
    this.experimental,
    this.extensions,
    this.raw,
  });

  final bool tools;
  final bool toolsListChanged;
  final bool resources;

  /// `resources.subscribe`: `resources/subscribe` is supported.
  final bool resourcesSubscribe;
  final bool resourcesListChanged;
  final bool prompts;
  final bool promptsListChanged;
  final bool logging;

  /// `completions`: `completion/complete` is supported.
  final bool completions;

  /// `tasks` (2025-11-25), as the protocol writes it.
  final Map<String, dynamic>? tasks;

  /// `experimental`: non-standard capabilities.
  final Map<String, Map<String, dynamic>>? experimental;

  /// `extensions` (2026-07-28): reverse-DNS id -> settings.
  final Map<String, Map<String, dynamic>>? extensions;

  /// The capabilities as received (every field, typed), when parsed.
  final ServerCapabilitiesSchema? raw;

  /// Whether the server advertises the extension [id].
  bool hasExtension(String id) => extensions?.containsKey(id) ?? false;

  factory ServerCapabilities.fromJson(Map<String, dynamic> json) {
    final c = schema.ServerCapabilities.fromJson(json);
    return ServerCapabilities(
      tools: c.tools != null,
      toolsListChanged: c.tools?.listChanged ?? false,
      resources: c.resources != null,
      resourcesSubscribe: c.resources?.subscribe ?? false,
      resourcesListChanged: c.resources?.listChanged ?? false,
      prompts: c.prompts != null,
      promptsListChanged: c.prompts?.listChanged ?? false,
      logging: c.logging != null,
      completions: c.completions != null,
      tasks: c.has('tasks') ? Map<String, dynamic>.from(c['tasks'] as Map) : null,
      experimental: c.experimental,
      extensions: c.extensions,
      raw: c,
    );
  }

  Map<String, dynamic> toJson() {
    if (raw != null) return raw!.toJson();
    return {
      if (tools) 'tools': {if (toolsListChanged) 'listChanged': true},
      if (resources)
        'resources': {
          if (resourcesSubscribe) 'subscribe': true,
          if (resourcesListChanged) 'listChanged': true,
        },
      if (prompts) 'prompts': {if (promptsListChanged) 'listChanged': true},
      if (logging) 'logging': <String, dynamic>{},
      if (completions) 'completions': <String, dynamic>{},
      if (tasks != null) 'tasks': tasks,
      if (experimental != null && experimental!.isNotEmpty) 'experimental': experimental,
      if (extensions != null && extensions!.isNotEmpty) 'extensions': extensions,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ServerCapabilities && _eq(toJson(), other.toJson());

  @override
  int get hashCode => toJson().toString().hashCode;

  @override
  String toString() => 'ServerCapabilities(${toJson()})';

  static bool _eq(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _eq(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_eq(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}

// ============================================================================
// Deferred Loading Support (Progressive Tool Disclosure)
// ============================================================================

/// Lightweight tool metadata (name + description only)
/// Used for token-efficient LLM context in deferred loading mode
@immutable
class ToolMetadata {
  final String name;
  final String description;

  const ToolMetadata({
    required this.name,
    required this.description,
  });

  /// Create from Tool object
  factory ToolMetadata.fromTool(Tool tool) => ToolMetadata(
        name: tool.name,
        description: tool.description ?? '',
      );

  /// Create from Map (for compatibility with McpClientManager.getTools())
  factory ToolMetadata.fromMap(Map<String, dynamic> map) => ToolMetadata(
        name: map['name'] as String,
        description: map['description'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolMetadata &&
          name == other.name &&
          description == other.description;

  @override
  int get hashCode => Object.hash(name, description);

  @override
  String toString() => 'ToolMetadata(name: $name, description: $description)';
}

/// Cache layer for tool definitions
/// Provides metadata extraction and full schema lookup
/// LLM-agnostic: can be used without mcp_llm
class ToolRegistry {
  final Map<String, ToolMetadata> _metadata = {};
  final Map<String, Map<String, dynamic>> _schemas = {};
  bool _initialized = false;

  /// Cache tools from Map list (McpClientManager.getTools() result)
  void cacheFromMaps(List<Map<String, dynamic>> tools) {
    _metadata.clear();
    _schemas.clear();
    for (final tool in tools) {
      final name = tool['name'] as String;
      _metadata[name] = ToolMetadata.fromMap(tool);
      _schemas[name] = Map<String, dynamic>.from(tool);
    }
    _initialized = true;
  }

  /// Cache tools from Tool list (Client.listTools() result)
  void cacheFromTools(List<Tool> tools) {
    _metadata.clear();
    _schemas.clear();
    for (final tool in tools) {
      _metadata[tool.name] = ToolMetadata.fromTool(tool);
      _schemas[tool.name] = tool.toJson();
    }
    _initialized = true;
  }

  /// Check if registry is initialized
  bool get isInitialized => _initialized;

  /// Get all metadata (lightweight, for LLM context)
  List<ToolMetadata> getAllMetadata() => _metadata.values.toList();

  /// Get metadata for specific tool
  ToolMetadata? getMetadata(String toolName) => _metadata[toolName];

  /// Get full tool schema as Map (for execution/validation)
  Map<String, dynamic>? getSchema(String toolName) => _schemas[toolName];

  /// Check if tool exists
  bool hasTool(String toolName) => _schemas.containsKey(toolName);

  /// Get all tool names
  List<String> get toolNames => _schemas.keys.toList();

  /// Clear cache (call on tools/list_changed notification)
  void invalidateAll() {
    _metadata.clear();
    _schemas.clear();
    _initialized = false;
  }

  /// Get tool count
  int get count => _schemas.length;
}
