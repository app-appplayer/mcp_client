/// MCP 2025-03-26 standard error codes and handling
library;

import 'dart:async';
import 'package:meta/meta.dart';

/// JSON-RPC 2.0 and MCP 2025-03-26 standard error codes
enum McpErrorCode {
  // JSON-RPC 2.0.
  parseError(-32700, "Parse error"),
  invalidRequest(-32600, "Invalid Request"),
  methodNotFound(-32601, "Method not found"),
  invalidParams(-32602, "Invalid params"),
  internalError(-32603, "Internal error"),

  // Assigned by the specification.
  resourceNotFound(-32002, "Resource not found"),
  urlElicitationRequired(-32042, "URL elicitation required"),
  headerMismatch(-32020, "Header mismatch"),
  missingRequiredClientCapability(-32021, "Missing required client capability"),
  unsupportedProtocolVersion(-32022, "Unsupported protocol version"),

  // Implementation-defined, outside the JSON-RPC reserved range: the
  // specification closes -32000..-32019 to new codes (2026-07-28) and tells
  // receivers to assume no meaning there, so these live at -31000..-31019. Kinds that answer the same way
  // share a code; [kindOf] keeps them apart in this package.
  serverError(-31000, "Server error"),
  toolNotFound(-32602, "Unknown tool"),
  promptNotFound(-32602, "Unknown prompt"),
  incompatibleVersion(-31004, "Incompatible protocol version"),
  unauthorized(-31005, "Unauthorized"),
  operationCancelled(-31006, "Operation cancelled"),
  rateLimited(-31007, "Rate limited"),
  timeoutError(-31008, "Timeout error"),
  connectionLost(-31009, "Connection lost"),
  protocolError(-31010, "Protocol error"),
  toolExecutionError(-31011, "Tool execution error"),
  resourceUnavailable(-31012, "Resource unavailable"),
  validationError(-31013, "Validation error"),
  quotaExceeded(-31014, "Quota exceeded"),
  serverOverloaded(-31015, "Server overloaded"),
  insufficientPermissions(-31016, "Insufficient permissions"),
  authenticationRequired(-31017, "Authentication required"),
  conflictError(-31018, "Conflict error"),
  configurationError(-31019, "Server configuration error"),

  // Further kinds, on the code of the kind they answer as.
  promptExecutionError(-31011, "Prompt execution error"),
  sessionExpired(-31017, "Session expired"),
  dependencyError(-31019, "Dependency error"),
  authenticationFailed(-31005, "Authentication failed"),
  tokenExpired(-31017, "Token expired"),
  tokenInvalid(-31005, "Token invalid"),
  connectionTimeout(-31008, "Connection timeout"),
  encodingError(-31010, "Encoding error"),
  compressionError(-31010, "Compression error"),
  resourceLocked(-31018, "Resource locked"),
  resourceCorrupted(-31012, "Resource corrupted"),
  resourceTooLarge(-31013, "Resource too large"),
  resourceAccessDenied(-31016, "Resource access denied"),
  toolUnavailable(-31012, "Tool unavailable"),
  toolTimeout(-31008, "Tool timeout"),
  toolConfigurationError(-31019, "Tool configuration error"),
  toolDependencyMissing(-31019, "Tool dependency missing"),
  maintenanceMode(-31015, "Server in maintenance mode"),
  storageError(-31000, "Storage error"),
  networkError(-31009, "Network error"),
  clientError(-31000, "Client error"),
  permissionDenied(-31016, "Permission denied");

  const McpErrorCode(this.code, this.message);
  
  final int code;
  final String message;
  
  /// Find enum by error code
  static McpErrorCode? fromCode(int code) {
    for (final errorCode in McpErrorCode.values) {
      if (errorCode.code == code) {
        return errorCode;
      }
    }
    return null;
  }
  
  /// Check error codes by category
  bool get isJsonRpcError => code >= -32768 && code <= -31000;

  /// A code the specification assigns (not implementation-defined).
  bool get isMcpError => const {-32002, -32042, -32020, -32021, -32022}.contains(code);

  bool get isAuthError => const {
        McpErrorCode.unauthorized,
        McpErrorCode.authenticationRequired,
        McpErrorCode.authenticationFailed,
        McpErrorCode.tokenExpired,
        McpErrorCode.tokenInvalid,
        McpErrorCode.insufficientPermissions,
      }.contains(this);

  bool get isTransportError => const {
        McpErrorCode.connectionLost,
        McpErrorCode.networkError,
        McpErrorCode.connectionTimeout,
        McpErrorCode.protocolError,
        McpErrorCode.encodingError,
        McpErrorCode.compressionError,
      }.contains(this);

  bool get isResourceError => const {
        McpErrorCode.resourceNotFound,
        McpErrorCode.resourceUnavailable,
        McpErrorCode.resourceLocked,
        McpErrorCode.resourceCorrupted,
        McpErrorCode.resourceTooLarge,
        McpErrorCode.resourceAccessDenied,
      }.contains(this);

  bool get isToolError => const {
        McpErrorCode.toolNotFound,
        McpErrorCode.toolExecutionError,
        McpErrorCode.toolUnavailable,
        McpErrorCode.toolTimeout,
        McpErrorCode.toolConfigurationError,
        McpErrorCode.toolDependencyMissing,
      }.contains(this);

  /// Raised on the client side (not a server answer).
  bool get isClientError => const {
        McpErrorCode.clientError,
        McpErrorCode.permissionDenied,
      }.contains(this);

  bool get isServerError => const {
        McpErrorCode.serverError,
        McpErrorCode.serverOverloaded,
        McpErrorCode.maintenanceMode,
        McpErrorCode.configurationError,
        McpErrorCode.storageError,
      }.contains(this);

  bool get isRetryable {
    switch (this) {
      case McpErrorCode.rateLimited:
      case McpErrorCode.timeoutError:
      case McpErrorCode.connectionLost:
      case McpErrorCode.connectionTimeout:
      case McpErrorCode.networkError:
      case McpErrorCode.serverError:
      case McpErrorCode.resourceUnavailable:
      case McpErrorCode.toolUnavailable:
        return true;
      default:
        return false;
    }
  }

  /// Check if error is critical
  bool get isCritical {
    switch (this) {
      case McpErrorCode.internalError:
      case McpErrorCode.incompatibleVersion:
      case McpErrorCode.protocolError:
      case McpErrorCode.resourceCorrupted:
      case McpErrorCode.dependencyError:
        return true;
      default:
        return false;
    }
  }
}

/// MCP error response
@immutable
class McpError implements Exception {
  /// Error code
  final McpErrorCode code;

  /// Error message (detailed)
  final String message;

  /// Error data (optional)
  final Map<String, dynamic>? data;

  /// Request ID (optional)
  final dynamic requestId;

  /// Error occurrence time
  final DateTime timestamp;

  /// Error trace ID
  final String? traceId;

  const McpError({
    required this.code,
    required this.message,
    this.data,
    this.requestId,
    required this.timestamp,
    this.traceId,
  });

  /// Create with standard error code
  factory McpError.standard(
    McpErrorCode code, {
    String? customMessage,
    Map<String, dynamic>? data,
    dynamic requestId,
    String? traceId,
  }) {
    return McpError(
      code: code,
      message: customMessage ?? code.message,
      data: data,
      requestId: requestId,
      timestamp: DateTime.now(),
      traceId: traceId,
    );
  }

  /// Create from JSON-RPC error response
  factory McpError.fromJsonRpc(
    Map<String, dynamic> errorResponse, {
    dynamic requestId,
  }) {
    final errorData = errorResponse['error'] as Map<String, dynamic>;
    final code = errorData['code'] as int;
    final message = errorData['message'] as String;
    final data = errorData['data'] as Map<String, dynamic>?;

    final mcpCode = McpErrorCode.fromCode(code) ?? McpErrorCode.serverError;

    return McpError(
      code: mcpCode,
      message: message,
      data: data,
      requestId: requestId ?? errorResponse['id'],
      timestamp: DateTime.now(),
    );
  }

  /// Create Parse Error
  factory McpError.parseError({String? details, dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.parseError,
      customMessage: details != null ? "Parse error: $details" : null,
      requestId: requestId,
    );
  }

  /// Create Invalid Request
  factory McpError.invalidRequest({String? details, dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.invalidRequest,
      customMessage: details != null ? "Invalid request: $details" : null,
      requestId: requestId,
    );
  }

  /// Create Method Not Found
  factory McpError.methodNotFound(String method, {dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.methodNotFound,
      customMessage: "Method not found: $method",
      data: {"method": method},
      requestId: requestId,
    );
  }

  /// Create Invalid Params
  factory McpError.invalidParams({String? details, dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.invalidParams,
      customMessage: details != null ? "Invalid params: $details" : null,
      requestId: requestId,
    );
  }

  /// Create Resource Not Found
  factory McpError.resourceNotFound(String uri, {dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.resourceNotFound,
      customMessage: "Resource not found: $uri",
      data: {"uri": uri},
      requestId: requestId,
    );
  }

  /// Create Tool Not Found
  factory McpError.toolNotFound(String toolName, {dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.toolNotFound,
      customMessage: "Tool not found: $toolName",
      data: {"tool": toolName},
      requestId: requestId,
    );
  }

  /// Create Unauthorized
  factory McpError.unauthorized({String? details, dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.unauthorized,
      customMessage: details != null ? "Unauthorized: $details" : null,
      requestId: requestId,
    );
  }

  /// Create Timeout
  factory McpError.timeout({int? timeoutMs, dynamic requestId}) {
    return McpError.standard(
      McpErrorCode.timeoutError,
      customMessage:
          timeoutMs != null ? "Operation timed out after ${timeoutMs}ms" : null,
      data: timeoutMs != null ? {"timeout_ms": timeoutMs} : null,
      requestId: requestId,
    );
  }

  /// Convert to JSON-RPC error response
  Map<String, dynamic> toJsonRpcError() {
    final error = <String, dynamic>{"code": code.code, "message": message};

    if (data != null) {
      error["data"] = data!;
    }

    final response = {"jsonrpc": "2.0", "error": error};

    if (requestId != null) {
      response["id"] = requestId;
    }

    return response;
  }

  /// Convert to JSON (for logging/debugging)
  Map<String, dynamic> toJson() {
    return {
      "code": code.code,
      "codeName": code.name,
      "message": message,
      if (data != null) "data": data,
      if (requestId != null) "requestId": requestId,
      "timestamp": timestamp.toIso8601String(),
      if (traceId != null) "traceId": traceId,
    };
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('McpError(${code.name}[${code.code}]: $message');

    if (data != null) {
      buffer.write(', data: $data');
    }

    if (requestId != null) {
      buffer.write(', requestId: $requestId');
    }

    buffer.write(')');
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is McpError &&
        other.code == code &&
        other.message == message &&
        other.requestId == requestId;
  }

  @override
  int get hashCode {
    return Object.hash(code, message, requestId);
  }
}

/// Error handling utility
class McpErrorHandler {
  /// Convert exception to MCP error
  static McpError fromException(
    dynamic exception, {
    McpErrorCode? fallbackCode,
    dynamic requestId,
    String? traceId,
  }) {
    if (exception is McpError) {
      return exception;
    }

    if (exception is TimeoutException) {
      return McpError.timeout(
        timeoutMs: exception.duration?.inMilliseconds,
        requestId: requestId,
      );
    }

    if (exception is FormatException) {
      return McpError.parseError(
        details: exception.message,
        requestId: requestId,
      );
    }

    // Default internal error
    return McpError.standard(
      fallbackCode ?? McpErrorCode.internalError,
      customMessage: exception.toString(),
      requestId: requestId,
      traceId: traceId,
    );
  }

  /// Check if error is retryable
  static bool shouldRetry(
    McpError error, {
    int retryCount = 0,
    int maxRetries = 3,
  }) {
    if (retryCount >= maxRetries) return false;
    return error.code.isRetryable;
  }

  /// Calculate retry delay (exponential backoff)
  static Duration getRetryDelay(
    int retryCount, {
    Duration baseDelay = const Duration(seconds: 1),
  }) {
    final multiplier = 1 << retryCount; // 2^retryCount
    return Duration(
      milliseconds: (baseDelay.inMilliseconds * multiplier).clamp(100, 30000),
    );
  }

  /// Error severity level
  static ErrorSeverity getSeverity(McpError error) {
    if (error.code.isCritical) {
      return ErrorSeverity.critical;
    }

    if (error.code.isRetryable) {
      return ErrorSeverity.warning;
    }

    switch (error.code) {
      case McpErrorCode.unauthorized:
      case McpErrorCode.authenticationRequired:
      case McpErrorCode.authenticationFailed:
        return ErrorSeverity.error;
      case McpErrorCode.validationError:
      case McpErrorCode.invalidParams:
        return ErrorSeverity.warning;
      default:
        return ErrorSeverity.error;
    }
  }
}

/// Error severity
enum ErrorSeverity { info, warning, error, critical }

/// Error context information
@immutable
class ErrorContext {
  final String operation;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  final String? userId;
  final String? sessionId;

  const ErrorContext({
    required this.operation,
    this.metadata,
    required this.timestamp,
    this.userId,
    this.sessionId,
  });

  Map<String, dynamic> toJson() => {
    "operation": operation,
    if (metadata != null) "metadata": metadata,
    "timestamp": timestamp.toIso8601String(),
    if (userId != null) "userId": userId,
    if (sessionId != null) "sessionId": sessionId,
  };
}
