/// MCP 2025-03-26 standard error codes and handling
library;

import 'dart:async';
import 'package:meta/meta.dart';

/// JSON-RPC 2.0 and MCP 2025-03-26 standard error codes
enum McpErrorCode {
  // JSON-RPC 2.0 standard error codes
  parseError(-32700, "Parse error"),
  invalidRequest(-32600, "Invalid Request"),
  methodNotFound(-32601, "Method not found"),
  invalidParams(-32602, "Invalid params"),
  internalError(-32603, "Internal error"),

  // JSON-RPC 2.0 reserved error code range
  serverError(-32000, "Server error"),

  // MCP 2025-03-26 specific error codes
  resourceNotFound(-32100, "Resource not found"),
  toolNotFound(-32101, "Tool not found"),
  promptNotFound(-32102, "Prompt not found"),
  incompatibleVersion(-32103, "Incompatible protocol version"),
  unauthorized(-32104, "Unauthorized"),
  operationCancelled(-32105, "Operation cancelled"),
  rateLimited(-32106, "Rate limited"),

  // Additional MCP error codes
  resourceUnavailable(-32107, "Resource unavailable"),
  toolExecutionError(-32108, "Tool execution error"),
  promptExecutionError(-32109, "Prompt execution error"),
  sessionExpired(-32110, "Session expired"),
  quotaExceeded(-32111, "Quota exceeded"),
  validationError(-32112, "Validation error"),
  conflictError(-32113, "Conflict error"),
  dependencyError(-32114, "Dependency error"),
  timeoutError(-32115, "Timeout error"),

  // Authentication related errors
  authenticationRequired(-32120, "Authentication required"),
  authenticationFailed(-32121, "Authentication failed"),
  insufficientPermissions(-32122, "Insufficient permissions"),
  tokenExpired(-32123, "Token expired"),
  tokenInvalid(-32124, "Token invalid"),

  // Transport related errors
  connectionLost(-32130, "Connection lost"),
  connectionTimeout(-32131, "Connection timeout"),
  protocolError(-32132, "Protocol error"),
  encodingError(-32133, "Encoding error"),
  compressionError(-32134, "Compression error"),

  // Resource related errors
  resourceLocked(-32140, "Resource locked"),
  resourceCorrupted(-32141, "Resource corrupted"),
  resourceTooLarge(-32142, "Resource too large"),
  resourceAccessDenied(-32143, "Resource access denied"),

  // Tool related errors
  toolUnavailable(-32150, "Tool unavailable"),
  toolTimeout(-32151, "Tool timeout"),
  toolConfigurationError(-32152, "Tool configuration error"),
  toolDependencyMissing(-32153, "Tool dependency missing"),

  // General client errors
  clientError(-32160, "Client error"),
  networkError(-32161, "Network error"),
  storageError(-32162, "Storage error"),
  permissionDenied(-32163, "Permission denied");

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
  bool get isJsonRpcError => code >= -32768 && code <= -32000;
  bool get isMcpError => code >= -32200 && code <= -32100;
  bool get isAuthError => code >= -32124 && code <= -32120;
  bool get isTransportError => code >= -32134 && code <= -32130;
  bool get isResourceError => code >= -32143 && code <= -32140;
  bool get isToolError => code >= -32153 && code <= -32150;
  bool get isClientError => code >= -32163 && code <= -32160;

  /// Check if error is retryable
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
