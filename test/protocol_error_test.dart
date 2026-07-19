/// Coverage for `lib/src/protocol/error.dart` (`McpErrorCode`, `McpError`,
/// `McpErrorHandler`, `ErrorSeverity`, `ErrorContext`).
///
/// This file is NOT reachable from `package:mcp_client/mcp_client.dart` — it
/// is not exported and not imported by any other source file in the package
/// (verified via `grep -rn "protocol/error" lib/`). It therefore carries
/// zero baseline coverage. `McpError` in this file collides in name with
/// `McpError` in `lib/src/models/models.dart` (the one actually exported by
/// the public `mcp_client.dart` barrel), so this file imports the source
/// path directly rather than the public barrel to avoid an ambiguous-import
/// error.
library;

import 'dart:async';

import 'package:mcp_client/src/protocol/error.dart';
import 'package:test/test.dart';

void main() {
  group('McpErrorCode.fromCode', () {
    test('resolves a known code to its enum value', () {
      expect(McpErrorCode.fromCode(-32700), McpErrorCode.parseError);
      expect(McpErrorCode.fromCode(-32101), McpErrorCode.toolNotFound);
    });

    test('returns null for an unknown code', () {
      expect(McpErrorCode.fromCode(-1), isNull);
    });
  });

  group('McpErrorCode category getters', () {
    test('isJsonRpcError covers the whole JSON-RPC reserved range', () {
      // Every McpErrorCode value (from -32700 through -32163) falls inside
      // the JSON-RPC reserved range [-32768, -32000], so isJsonRpcError is
      // true package-wide; this predicate exists to classify codes from
      // outside this enum (e.g. server-defined codes below -32768 or above
      // -32000) and cannot be exercised as false with only enum members.
      expect(McpErrorCode.parseError.isJsonRpcError, isTrue);
      expect(McpErrorCode.serverError.isJsonRpcError, isTrue);
      expect(McpErrorCode.resourceNotFound.isJsonRpcError, isTrue);
      expect(McpErrorCode.permissionDenied.isJsonRpcError, isTrue);
    });

    test('isMcpError covers the MCP-specific range', () {
      expect(McpErrorCode.resourceNotFound.isMcpError, isTrue);
      expect(McpErrorCode.parseError.isMcpError, isFalse);
    });

    test('isAuthError covers authentication codes', () {
      expect(McpErrorCode.authenticationRequired.isAuthError, isTrue);
      expect(McpErrorCode.tokenInvalid.isAuthError, isTrue);
      expect(McpErrorCode.parseError.isAuthError, isFalse);
    });

    test('isTransportError covers transport codes', () {
      expect(McpErrorCode.connectionLost.isTransportError, isTrue);
      expect(McpErrorCode.compressionError.isTransportError, isTrue);
      expect(McpErrorCode.parseError.isTransportError, isFalse);
    });

    test('isResourceError covers resource codes', () {
      expect(McpErrorCode.resourceLocked.isResourceError, isTrue);
      expect(McpErrorCode.resourceAccessDenied.isResourceError, isTrue);
      expect(McpErrorCode.parseError.isResourceError, isFalse);
    });

    test('isToolError covers tool codes', () {
      expect(McpErrorCode.toolUnavailable.isToolError, isTrue);
      expect(McpErrorCode.toolDependencyMissing.isToolError, isTrue);
      expect(McpErrorCode.parseError.isToolError, isFalse);
    });

    test('isClientError covers client codes', () {
      expect(McpErrorCode.clientError.isClientError, isTrue);
      expect(McpErrorCode.permissionDenied.isClientError, isTrue);
      expect(McpErrorCode.parseError.isClientError, isFalse);
    });
  });

  group('McpErrorCode.isRetryable', () {
    test('true for all retryable codes', () {
      for (final code in [
        McpErrorCode.rateLimited,
        McpErrorCode.timeoutError,
        McpErrorCode.connectionLost,
        McpErrorCode.connectionTimeout,
        McpErrorCode.networkError,
        McpErrorCode.serverError,
        McpErrorCode.resourceUnavailable,
        McpErrorCode.toolUnavailable,
      ]) {
        expect(code.isRetryable, isTrue, reason: code.name);
      }
    });

    test('false for a non-retryable code', () {
      expect(McpErrorCode.invalidParams.isRetryable, isFalse);
    });
  });

  group('McpErrorCode.isCritical', () {
    test('true for all critical codes', () {
      for (final code in [
        McpErrorCode.internalError,
        McpErrorCode.incompatibleVersion,
        McpErrorCode.protocolError,
        McpErrorCode.resourceCorrupted,
        McpErrorCode.dependencyError,
      ]) {
        expect(code.isCritical, isTrue, reason: code.name);
      }
    });

    test('false for a non-critical code', () {
      expect(McpErrorCode.invalidParams.isCritical, isFalse);
    });
  });

  group('McpError construction', () {
    test('const constructor carries all fields', () {
      final now = DateTime.now();
      final error = McpError(
        code: McpErrorCode.internalError,
        message: 'boom',
        data: {'k': 'v'},
        requestId: 5,
        timestamp: now,
        traceId: 'trace-1',
      );
      expect(error.code, McpErrorCode.internalError);
      expect(error.message, 'boom');
      expect(error.data, {'k': 'v'});
      expect(error.requestId, 5);
      expect(error.timestamp, now);
      expect(error.traceId, 'trace-1');
    });

    test('McpError.standard uses the code default message when unset', () {
      final error = McpError.standard(McpErrorCode.toolNotFound);
      expect(error.message, McpErrorCode.toolNotFound.message);
    });

    test('McpError.standard honors a custom message and metadata', () {
      final error = McpError.standard(
        McpErrorCode.toolNotFound,
        customMessage: 'custom',
        data: {'a': 1},
        requestId: 9,
        traceId: 't1',
      );
      expect(error.message, 'custom');
      expect(error.data, {'a': 1});
      expect(error.requestId, 9);
      expect(error.traceId, 't1');
    });

    test('McpError.fromJsonRpc parses a JSON-RPC error response', () {
      final error = McpError.fromJsonRpc({
        'error': {
          'code': -32101,
          'message': 'Tool not found: t1',
          'data': {'tool': 't1'},
        },
        'id': 3,
      });
      expect(error.code, McpErrorCode.toolNotFound);
      expect(error.message, 'Tool not found: t1');
      expect(error.data, {'tool': 't1'});
      expect(error.requestId, 3);
    });

    test('McpError.fromJsonRpc falls back to serverError for unknown codes',
        () {
      final error = McpError.fromJsonRpc({
        'error': {'code': -99999, 'message': 'weird'},
      });
      expect(error.code, McpErrorCode.serverError);
    });

    test('McpError.fromJsonRpc prefers explicit requestId over response id',
        () {
      final error = McpError.fromJsonRpc(
        {
          'error': {'code': -32700, 'message': 'x'},
          'id': 1,
        },
        requestId: 2,
      );
      expect(error.requestId, 2);
    });

    test('factory helpers build the expected standard errors', () {
      expect(McpError.parseError().code, McpErrorCode.parseError);
      expect(
        McpError.parseError(details: 'bad json').message,
        'Parse error: bad json',
      );
      expect(McpError.invalidRequest().code, McpErrorCode.invalidRequest);
      expect(
        McpError.invalidRequest(details: 'x').message,
        'Invalid request: x',
      );
      expect(McpError.methodNotFound('tools/list').message,
          'Method not found: tools/list');
      expect(McpError.methodNotFound('tools/list').data, {
        'method': 'tools/list',
      });
      expect(McpError.invalidParams().code, McpErrorCode.invalidParams);
      expect(
        McpError.invalidParams(details: 'missing x').message,
        'Invalid params: missing x',
      );
      expect(McpError.resourceNotFound('file:///a').data, {'uri': 'file:///a'});
      expect(McpError.toolNotFound('calc').data, {'tool': 'calc'});
      expect(McpError.unauthorized().code, McpErrorCode.unauthorized);
      expect(
        McpError.unauthorized(details: 'expired').message,
        'Unauthorized: expired',
      );
      expect(McpError.timeout().code, McpErrorCode.timeoutError);
      expect(
        McpError.timeout(timeoutMs: 3000).message,
        'Operation timed out after 3000ms',
      );
      expect(McpError.timeout(timeoutMs: 3000).data, {'timeout_ms': 3000});
    });

    test('toJsonRpcError includes data and id only when set', () {
      final withExtras = McpError.standard(
        McpErrorCode.toolNotFound,
        data: {'tool': 't1'},
        requestId: 5,
      );
      final rpc = withExtras.toJsonRpcError();
      expect(rpc['jsonrpc'], '2.0');
      expect((rpc['error'] as Map)['data'], {'tool': 't1'});
      expect(rpc['id'], 5);

      final bare = McpError.standard(McpErrorCode.toolNotFound);
      final bareRpc = bare.toJsonRpcError();
      expect((bareRpc['error'] as Map).containsKey('data'), isFalse);
      expect(bareRpc.containsKey('id'), isFalse);
    });

    test('toJson includes optional fields only when set', () {
      final full = McpError.standard(
        McpErrorCode.toolNotFound,
        data: {'tool': 't1'},
        requestId: 5,
        traceId: 'tr1',
      );
      final json = full.toJson();
      expect(json['code'], McpErrorCode.toolNotFound.code);
      expect(json['codeName'], 'toolNotFound');
      expect(json['data'], {'tool': 't1'});
      expect(json['requestId'], 5);
      expect(json['traceId'], 'tr1');

      final bare = McpError.standard(McpErrorCode.toolNotFound);
      final bareJson = bare.toJson();
      expect(bareJson.containsKey('data'), isFalse);
      expect(bareJson.containsKey('requestId'), isFalse);
      expect(bareJson.containsKey('traceId'), isFalse);
    });

    test('toString includes data and requestId only when set', () {
      final full = McpError.standard(
        McpErrorCode.toolNotFound,
        data: {'tool': 't1'},
        requestId: 5,
      );
      final str = full.toString();
      expect(str, contains('toolNotFound'));
      expect(str, contains('data:'));
      expect(str, contains('requestId: 5'));

      final bare = McpError.standard(McpErrorCode.toolNotFound);
      final bareStr = bare.toString();
      expect(bareStr, isNot(contains('data:')));
      expect(bareStr, isNot(contains('requestId:')));
    });

    test('operator== and hashCode compare code/message/requestId', () {
      final now = DateTime.now();
      final a = McpError(
        code: McpErrorCode.toolNotFound,
        message: 'x',
        requestId: 1,
        timestamp: now,
      );
      final b = McpError(
        code: McpErrorCode.toolNotFound,
        message: 'x',
        requestId: 1,
        timestamp: now.add(const Duration(seconds: 1)),
      );
      final c = McpError(
        code: McpErrorCode.toolNotFound,
        message: 'different',
        requestId: 1,
        timestamp: now,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, equals(a));
    });
  });

  group('McpErrorHandler.fromException', () {
    test('passes through an existing McpError unchanged', () {
      final original = McpError.standard(McpErrorCode.toolNotFound);
      expect(McpErrorHandler.fromException(original), same(original));
    });

    test('maps a TimeoutException to a timeout McpError', () {
      final exception = TimeoutException('timed out', const Duration(seconds: 2));
      final error = McpErrorHandler.fromException(exception);
      expect(error.code, McpErrorCode.timeoutError);
      expect(error.data, {'timeout_ms': 2000});
    });

    test('maps a FormatException to a parseError McpError', () {
      final exception = const FormatException('bad json');
      final error = McpErrorHandler.fromException(exception);
      expect(error.code, McpErrorCode.parseError);
      expect(error.message, 'Parse error: bad json');
    });

    test('maps a generic exception to internalError by default', () {
      final error = McpErrorHandler.fromException(Exception('generic'));
      expect(error.code, McpErrorCode.internalError);
      expect(error.message, contains('generic'));
    });

    test('honors a custom fallbackCode for a generic exception', () {
      final error = McpErrorHandler.fromException(
        Exception('generic'),
        fallbackCode: McpErrorCode.clientError,
        requestId: 1,
        traceId: 't1',
      );
      expect(error.code, McpErrorCode.clientError);
      expect(error.requestId, 1);
      expect(error.traceId, 't1');
    });
  });

  group('McpErrorHandler.shouldRetry', () {
    test('false once retryCount reaches maxRetries', () {
      final error = McpError.standard(McpErrorCode.rateLimited);
      expect(
        McpErrorHandler.shouldRetry(error, retryCount: 3, maxRetries: 3),
        isFalse,
      );
    });

    test('true for a retryable code under the retry limit', () {
      final error = McpError.standard(McpErrorCode.rateLimited);
      expect(
        McpErrorHandler.shouldRetry(error, retryCount: 0, maxRetries: 3),
        isTrue,
      );
    });

    test('false for a non-retryable code under the retry limit', () {
      final error = McpError.standard(McpErrorCode.invalidParams);
      expect(
        McpErrorHandler.shouldRetry(error, retryCount: 0, maxRetries: 3),
        isFalse,
      );
    });
  });

  group('McpErrorHandler.getRetryDelay', () {
    test('doubles per retry count (exponential backoff)', () {
      final d0 = McpErrorHandler.getRetryDelay(0);
      final d1 = McpErrorHandler.getRetryDelay(1);
      final d2 = McpErrorHandler.getRetryDelay(2);
      expect(d0, const Duration(seconds: 1));
      expect(d1, const Duration(seconds: 2));
      expect(d2, const Duration(seconds: 4));
    });

    test('clamps to the [100ms, 30s] range', () {
      final tiny = McpErrorHandler.getRetryDelay(
        0,
        baseDelay: const Duration(milliseconds: 1),
      );
      expect(tiny.inMilliseconds, 100);

      final huge = McpErrorHandler.getRetryDelay(20);
      expect(huge.inMilliseconds, 30000);
    });
  });

  group('McpErrorHandler.getSeverity', () {
    test('critical codes report critical severity', () {
      final error = McpError.standard(McpErrorCode.internalError);
      expect(McpErrorHandler.getSeverity(error), ErrorSeverity.critical);
    });

    test('retryable non-critical codes report warning severity', () {
      final error = McpError.standard(McpErrorCode.rateLimited);
      expect(McpErrorHandler.getSeverity(error), ErrorSeverity.warning);
    });

    test('auth codes report error severity', () {
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.unauthorized),
        ),
        ErrorSeverity.error,
      );
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.authenticationRequired),
        ),
        ErrorSeverity.error,
      );
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.authenticationFailed),
        ),
        ErrorSeverity.error,
      );
    });

    test('validation-style codes report warning severity', () {
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.validationError),
        ),
        ErrorSeverity.warning,
      );
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.invalidParams),
        ),
        ErrorSeverity.warning,
      );
    });

    test('unclassified codes default to error severity', () {
      expect(
        McpErrorHandler.getSeverity(
          McpError.standard(McpErrorCode.resourceNotFound),
        ),
        ErrorSeverity.error,
      );
    });
  });

  group('ErrorContext', () {
    test('toJson includes optional fields only when set', () {
      final full = ErrorContext(
        operation: 'tools/call',
        metadata: {'tool': 't1'},
        timestamp: DateTime.utc(2024, 1, 1),
        userId: 'u1',
        sessionId: 's1',
      );
      final json = full.toJson();
      expect(json['operation'], 'tools/call');
      expect(json['metadata'], {'tool': 't1'});
      expect(json['userId'], 'u1');
      expect(json['sessionId'], 's1');

      final bare = ErrorContext(
        operation: 'tools/call',
        timestamp: DateTime.utc(2024, 1, 1),
      );
      final bareJson = bare.toJson();
      expect(bareJson.containsKey('metadata'), isFalse);
      expect(bareJson.containsKey('userId'), isFalse);
      expect(bareJson.containsKey('sessionId'), isFalse);
    });
  });
}
