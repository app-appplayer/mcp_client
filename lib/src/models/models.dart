/// Base content type enum for MCP
enum MessageRole {
  user,
  assistant,
  system,
}

enum MCPContentType {
  text,
  image,
  resource,
}

/// Base class for all MCP content types
abstract class Content {
  final MCPContentType type;

  Content(this.type);

  Map<String, dynamic> toJson();

  // Factory constructor for creating content from JSON
  static Content fromJson(Map<String, dynamic> json) {
    final contentType = json['type'] as String?;

    switch (contentType) {
      case 'text':
        return TextContent(text: json['text'] as String);
      case 'image':
        return ImageContent(
          url: json['url'] as String?,
          data: json['data'] as String?,
          mimeType: json['mimeType'] as String,
        );
      case 'resource':
        final resource = ResourceContent(
          uri: json['uri'] as String,
          text: json['text'] as String?,
          blob: json['blob'] as String?,
          mimeType: json['mimeType'] as String?,
        );
        return resource;
      default:
        throw FormatException('Unknown content type: $contentType');
    }
  }
}

/// Text content representation
class TextContent extends Content {
  final String text;

  TextContent({required this.text}) : super(MCPContentType.text);

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'text',
      'text': text,
    };
  }

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(text: json['text'] as String);
  }
}

/// Image content representation
class ImageContent extends Content {
  final String? url;
  final String? data;
  final String mimeType;

  ImageContent({
    this.url,
    this.data,
    required this.mimeType,
  }) : super(MCPContentType.image);

  factory ImageContent.fromBase64({
    required String data,
    required String mimeType,
  }) {
    return ImageContent(
      data: data,
      mimeType: mimeType,
    );
  }

  factory ImageContent.fromJson(Map<String, dynamic> json) {
    return ImageContent(
      url: json['url'] as String?,
      data: json['data'] as String?,
      mimeType: json['mimeType'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'type': 'image',
      'mimeType': mimeType,
    };

    if (url != null) {
      result['url'] = url;
    }

    if (data != null) {
      result['data'] = data;
    }

    return result;
  }
}

/// Resource content representation
class ResourceContent extends Content {
  final String uri;
  final String? text;
  final String? blob;
  final String? mimeType;
  final Map<String, dynamic>? uriTemplate;

  ResourceContent({
    required this.uri,
    this.text,
    this.blob,
    this.mimeType,
    this.uriTemplate,
  }) : super(MCPContentType.resource);

  factory ResourceContent.fromJson(Map<String, dynamic> json) {
    return ResourceContent(
      uri: json['uri'] as String,
      text: json['text'] as String?,
      blob: json['blob'] as String?,
      mimeType: json['mimeType'] as String?,
      uriTemplate: json['uriTemplate'] as Map<String, dynamic>?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'type': 'resource',
      'uri': uri,
    };

    if (text != null) {
      result['text'] = text;
    }

    if (blob != null) {
      result['blob'] = blob;
    }

    if (mimeType != null) {
      result['mimeType'] = mimeType;
    }

    return result;
  }
}

/// Tool definition
class Tool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Tool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
    };
  }

  factory Tool.fromJson(Map<String, dynamic> json) {
    return Tool(
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      inputSchema: (json['inputSchema'] as Map<dynamic, dynamic>).cast<String, dynamic>(),
    );
  }
}

/// Tool call result
class CallToolResult {
  final List<Content> content;
  final bool isStreaming;
  final bool? isError;

  CallToolResult(
      this.content, {
        this.isStreaming = false,
        this.isError,
      });

  Map<String, dynamic> toJson() {
    return {
      'content': content.map((c) => c.toJson()).toList(),
      'isStreaming': isStreaming,
      if (isError != null) 'isError': isError,
    };
  }

  factory CallToolResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> contentList = json['content'] as List<dynamic>? ?? [];
    final List<Content> contents = contentList.map((contentData) {
      final contentMap = contentData as Map<String, dynamic>;
      return Content.fromJson(contentMap);
    }).toList();

    return CallToolResult(
      contents,
      isStreaming: json['isStreaming'] as bool? ?? false,
      isError: json['isError'] as bool?,
    );
  }
}

/// Resource definition
class Resource {
  final String uri;
  final String name;
  final String description;
  final String? mimeType;
  final Map<String, dynamic>? uriTemplate;

  Resource({
    required this.uri,
    required this.name,
    required this.description,
    this.mimeType,
    this.uriTemplate,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'uri': uri,
      'name': name,
      'description': description,
    };

    if (mimeType != null) {
      result['mimeType'] = mimeType;
    }

    if (uriTemplate != null) {
      result['uriTemplate'] = uriTemplate;
    }

    return result;
  }

  factory Resource.fromJson(Map<String, dynamic> json) {
    return Resource(
      uri: json['uri'] as String,
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      mimeType: json['mimeType'] as String?,
      uriTemplate: json['uriTemplate'] as Map<String, dynamic>?,
    );
  }
}

/// Resource template definition
class ResourceTemplate {
  final String uriTemplate;
  final String name;
  final String description;
  final String? mimeType;

  ResourceTemplate({
    required this.uriTemplate,
    required this.name,
    required this.description,
    this.mimeType,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'uriTemplate': uriTemplate,
      'name': name,
      'description': description,
    };

    if (mimeType != null) {
      result['mimeType'] = mimeType;
    }

    return result;
  }

  factory ResourceTemplate.fromJson(Map<String, dynamic> json) {
    return ResourceTemplate(
      uriTemplate: json['uriTemplate'] as String,
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      mimeType: json['mimeType'] as String?,
    );
  }
}

/// Resource content
class ResourceContentInfo {
  final String uri;
  final String? mimeType;
  final String? text;
  final String? blob;

  ResourceContentInfo({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {'uri': uri};

    if (mimeType != null) {
      result['mimeType'] = mimeType;
    }

    if (text != null) {
      result['text'] = text;
    }

    if (blob != null) {
      result['blob'] = blob;
    }

    return result;
  }

  factory ResourceContentInfo.fromJson(Map<String, dynamic> json) {
    return ResourceContentInfo(
      uri: json['uri'] as String,
      mimeType: json['mimeType'] as String?,
      text: json['text'] as String?,
      blob: json['blob'] as String?,
    );
  }
}

/// Resource read result
class ReadResourceResult {
  final List<ResourceContentInfo> contents;

  ReadResourceResult({
    required this.contents,
  });

  Map<String, dynamic> toJson() {
    return {
      'contents': contents.map((c) => c.toJson()).toList(),
    };
  }

  factory ReadResourceResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> contentsList = json['contents'] as List<dynamic>? ?? [];
    final contents = contentsList
        .map((content) => ResourceContentInfo.fromJson(content as Map<String, dynamic>))
        .toList();

    return ReadResourceResult(contents: contents);
  }
}

/// Prompt argument definition
class PromptArgument {
  final String name;
  final String description;
  final bool required;
  final String? defaultValue;

  PromptArgument({
    required this.name,
    required this.description,
    this.required = false,
    this.defaultValue,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'name': name,
      'description': description,
      'required': required,
    };

    if (defaultValue != null) {
      result['default'] = defaultValue;
    }

    return result;
  }

  factory PromptArgument.fromJson(Map<String, dynamic> json) {
    return PromptArgument(
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      required: json['required'] as bool? ?? false,
      defaultValue: json['default'] as String?,
    );
  }
}

/// Prompt definition
class Prompt {
  final String name;
  final String description;
  final List<PromptArgument> arguments;

  Prompt({
    required this.name,
    required this.description,
    required this.arguments,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'arguments': arguments.map((arg) => arg.toJson()).toList(),
    };
  }

  factory Prompt.fromJson(Map<String, dynamic> json) {
    final List<dynamic> argsList = json['arguments'] as List<dynamic>? ?? [];
    final arguments = argsList
        .map((arg) => PromptArgument.fromJson(arg as Map<String, dynamic>))
        .toList();

    return Prompt(
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      arguments: arguments,
    );
  }
}

/// Message model for prompt system
class Message {
  final String role;
  final Content content;

  Message({
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content.toJson(),
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    final contentMap = json['content'] as Map<String, dynamic>;

    return Message(
      role: json['role'] as String,
      content: Content.fromJson(contentMap),
    );
  }
}

/// Get prompt result
class GetPromptResult {
  final String? description;
  final List<Message> messages;

  GetPromptResult({
    this.description,
    required this.messages,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'messages': messages.map((m) => m.toJson()).toList(),
    };

    if (description != null) {
      result['description'] = description;
    }

    return result;
  }

  factory GetPromptResult.fromJson(Map<String, dynamic> json) {
    final List<dynamic> messagesList = json['messages'] as List<dynamic>? ?? [];
    final messages = messagesList
        .map((message) => Message.fromJson(message as Map<String, dynamic>))
        .toList();

    return GetPromptResult(
      description: json['description'] as String?,
      messages: messages,
    );
  }
}

/// Model hint for sampling
class ModelHint {
  final String name;
  final double? weight;

  ModelHint({
    required this.name,
    this.weight,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {'name': name};
    if (weight != null) {
      result['weight'] = weight;
    }
    return result;
  }

  factory ModelHint.fromJson(Map<String, dynamic> json) {
    return ModelHint(
      name: json['name'] as String,
      weight: json['weight'] as double?,
    );
  }
}

/// Model preferences for sampling
class ModelPreferences {
  final List<ModelHint>? hints;
  final double? costPriority;
  final double? speedPriority;
  final double? intelligencePriority;

  ModelPreferences({
    this.hints,
    this.costPriority,
    this.speedPriority,
    this.intelligencePriority,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = <String, dynamic>{};

    if (hints != null && hints!.isNotEmpty) {
      result['hints'] = hints!.map((h) => h.toJson()).toList();
    }

    if (costPriority != null) {
      result['costPriority'] = costPriority;
    }

    if (speedPriority != null) {
      result['speedPriority'] = speedPriority;
    }

    if (intelligencePriority != null) {
      result['intelligencePriority'] = intelligencePriority;
    }

    return result;
  }

  factory ModelPreferences.fromJson(Map<String, dynamic> json) {
    final List<dynamic>? hintsList = json['hints'] as List<dynamic>?;
    final hints = hintsList
        ?.map((hint) => ModelHint.fromJson(hint as Map<String, dynamic>))
        .toList();

    return ModelPreferences(
      hints: hints,
      costPriority: json['costPriority'] as double?,
      speedPriority: json['speedPriority'] as double?,
      intelligencePriority: json['intelligencePriority'] as double?,
    );
  }
}

/// Create message request for sampling
class CreateMessageRequest {
  final List<Message> messages;
  final ModelPreferences? modelPreferences;
  final String? systemPrompt;
  final String? includeContext;
  final int? maxTokens;
  final double? temperature;
  final List<String>? stopSequences;
  final Map<String, dynamic>? metadata;

  CreateMessageRequest({
    required this.messages,
    this.modelPreferences,
    this.systemPrompt,
    this.includeContext,
    this.maxTokens,
    this.temperature,
    this.stopSequences,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'messages': messages.map((m) => m.toJson()).toList(),
    };

    if (modelPreferences != null) {
      result['modelPreferences'] = modelPreferences!.toJson();
    }

    if (systemPrompt != null) {
      result['systemPrompt'] = systemPrompt;
    }

    if (includeContext != null) {
      result['includeContext'] = includeContext;
    }

    if (maxTokens != null) {
      result['maxTokens'] = maxTokens;
    }

    if (temperature != null) {
      result['temperature'] = temperature;
    }

    if (stopSequences != null && stopSequences!.isNotEmpty) {
      result['stopSequences'] = stopSequences;
    }

    if (metadata != null && metadata!.isNotEmpty) {
      result['metadata'] = Map<String, dynamic>.from(metadata!);
    }

    return result;
  }

  factory CreateMessageRequest.fromJson(Map<String, dynamic> json) {
    final List<dynamic> messagesList = json['messages'] as List<dynamic>? ?? [];
    final messages = messagesList
        .map((message) => Message.fromJson(message as Map<String, dynamic>))
        .toList();

    // 추출 및 변환
    final List<dynamic>? stopSequencesList = json['stopSequences'] as List<dynamic>?;
    final stopSequences = stopSequencesList
        ?.map((sequence) => sequence as String)
        .toList();

    return CreateMessageRequest(
      messages: messages,
      modelPreferences: json['modelPreferences'] != null
          ? ModelPreferences.fromJson(json['modelPreferences'] as Map<String, dynamic>)
          : null,
      systemPrompt: json['systemPrompt'] as String?,
      includeContext: json['includeContext'] as String?,
      maxTokens: json['maxTokens'] as int?,
      temperature: json['temperature'] as double?,
      stopSequences: stopSequences,
      metadata: json['metadata'] != null
          ? (json['metadata'] as Map<dynamic, dynamic>).cast<String, dynamic>()
          : null,
    );
  }
}

/// Create message result from sampling
class CreateMessageResult {
  final String model;
  final String? stopReason;
  final String role;
  final Content content;

  CreateMessageResult({
    required this.model,
    this.stopReason,
    required this.role,
    required this.content,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'model': model,
      'role': role,
      'content': content.toJson(),
    };

    if (stopReason != null) {
      result['stopReason'] = stopReason;
    }

    return result;
  }

  factory CreateMessageResult.fromJson(Map<String, dynamic> json) {
    final contentMap = json['content'] as Map<String, dynamic>;

    return CreateMessageResult(
      model: json['model'] as String,
      stopReason: json['stopReason'] as String?,
      role: json['role'] as String,
      content: Content.fromJson(contentMap),
    );
  }
}

/// Root definition for filesystem access
class Root {
  final String uri;
  final String name;
  final String? description;

  Root({
    required this.uri,
    required this.name,
    this.description,
  });

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> result = {
      'uri': uri,
      'name': name,
    };

    if (description != null) {
      result['description'] = description;
    }

    return result;
  }

  factory Root.fromJson(Map<String, dynamic> json) {
    return Root(
      uri: json['uri'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
    );
  }
}

/// Error class for MCP-related errors
class McpError implements Exception {
  final String message;
  final int? code;

  McpError(this.message, {this.code});

  @override
  String toString() => 'McpError ${code != null ? '($code)' : ''}: $message';
}

/// JSON-RPC message
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

  JsonRpcMessage({
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
        params = (json['params'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      } else {
        throw FormatException('Invalid params: expected a Map, got ${json['params'].runtimeType}');
      }
    }

    // Ensure error is properly typed as Map<String, dynamic>
    Map<String, dynamic>? error;
    if (json['error'] != null) {
      if (json['error'] is Map) {
        error = (json['error'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      } else {
        throw FormatException('Invalid error: expected a Map, got ${json['error'].runtimeType}');
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
    final Map<String, dynamic> json = {'jsonrpc': jsonrpc};

    if (id != null) {
      json['id'] = id;
    }

    if (method != null) {
      json['method'] = method;
    }

    if (params != null) {
      json['params'] = params;
    }

    if (result != null) {
      json['result'] = result;
    }

    if (error != null) {
      json['error'] = error;
    }

    return json;
  }
}

/// Server health information
class ServerHealth {
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

  ServerHealth({
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
      isRunning: json['isRunning'] as bool,
      connectedSessions: json['connectedSessions'] as int,
      registeredTools: json['registeredTools'] as int,
      registeredResources: json['registeredResources'] as int,
      registeredPrompts: json['registeredPrompts'] as int,
      startTime: DateTime.parse(json['startTime'] as String),
      uptime: Duration(seconds: json['uptimeSeconds'] as int),
      metrics: json['metrics'] as Map<String, dynamic>,
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
    this.requestId,
  }) : createdAt = DateTime.now();

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
      requestId: json['requestId'] as String?,
    );

    operation.isCancelled = json['isCancelled'] as bool? ?? false;

    return operation;
  }
}

/// Progress update for long-running operations
class ProgressUpdate {
  /// ID of the request this progress relates to
  final String requestId;

  /// Progress value between 0.0 and 1.0
  final double progress;

  /// Optional message describing the current status
  final String message;

  ProgressUpdate({
    required this.requestId,
    required this.progress,
    required this.message,
  });

  factory ProgressUpdate.fromJson(Map<String, dynamic> json) {
    return ProgressUpdate(
      requestId: json['requestId'] as String,
      progress: json['progress'] as double,
      message: json['message'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'requestId': requestId,
      'progress': progress,
      'message': message,
    };
  }
}

/// Cached resource item for performance optimization
class CachedResource {
  /// URI of the cached resource
  final String uri;

  /// Content of the resource
  final ReadResourceResult content;

  /// When the resource was cached
  final DateTime cachedAt;

  /// How long the cache should be valid
  final Duration maxAge;

  CachedResource({
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

/// Logging levels for MCP protocol
enum McpLogLevel {
  debug,
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency
}
