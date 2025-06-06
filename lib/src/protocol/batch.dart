/// JSON-RPC batching support for MCP 2025-03-26
library;

import 'dart:async';
import 'package:meta/meta.dart';

import '../transport/transport.dart';

/// JSON-RPC batch request
@immutable
class BatchRequest {
  /// Individual requests in the batch
  final List<Map<String, dynamic>> requests;

  /// Maximum time to wait before sending incomplete batch
  final Duration timeout;

  /// Maximum number of requests in a batch
  final int maxBatchSize;

  const BatchRequest({
    required this.requests,
    this.timeout = const Duration(milliseconds: 100),
    this.maxBatchSize = 10,
  });

  /// Convert to JSON array
  List<dynamic> toJson() => requests;

  /// Create from JSON array
  factory BatchRequest.fromJson(List<dynamic> json) =>
      BatchRequest(requests: json.cast<Map<String, dynamic>>());

  /// Check if batch is full
  bool get isFull => requests.length >= maxBatchSize;

  /// Check if batch is empty
  bool get isEmpty => requests.isEmpty;

  /// Number of requests in batch
  int get length => requests.length;
}

/// JSON-RPC batch response
@immutable
class BatchResponse {
  /// Individual responses in the batch
  final List<Map<String, dynamic>> responses;

  const BatchResponse({required this.responses});

  /// Convert to JSON array
  List<dynamic> toJson() => responses;

  /// Create from JSON array
  factory BatchResponse.fromJson(List<dynamic> json) =>
      BatchResponse(responses: json.cast<Map<String, dynamic>>());

  /// Get response by request ID
  Map<String, dynamic>? getResponseById(dynamic id) {
    for (final response in responses) {
      if (response['id'] == id) {
        return response;
      }
    }
    return null;
  }

  /// Get all successful responses
  List<Map<String, dynamic>> get successfulResponses {
    return responses.where((r) => r['error'] == null).toList();
  }

  /// Get all error responses
  List<Map<String, dynamic>> get errorResponses {
    return responses.where((r) => r['error'] != null).toList();
  }
}

/// Batch request builder and manager
class BatchManager {
  final Duration defaultTimeout;
  final int defaultMaxBatchSize;
  final Function(BatchRequest) onBatchReady;

  final List<Map<String, dynamic>> _pendingRequests = [];
  final Map<dynamic, Completer<dynamic>> _pendingCompleters = {};
  Timer? _batchTimer;

  BatchManager({
    this.defaultTimeout = const Duration(milliseconds: 100),
    this.defaultMaxBatchSize = 10,
    required this.onBatchReady,
  });

  /// Add a request to the current batch
  Future<dynamic> addRequest(Map<String, dynamic> request) {
    final completer = Completer<dynamic>();
    final id = request['id'];

    if (id != null) {
      _pendingCompleters[id] = completer;
    }

    _pendingRequests.add(request);

    // Check if we should send the batch immediately
    if (_pendingRequests.length >= defaultMaxBatchSize) {
      _sendBatch();
    } else {
      // Start timer for partial batches
      _batchTimer ??= Timer(defaultTimeout, _sendBatch);
    }

    return completer.future;
  }

  /// Send the current batch
  void _sendBatch() {
    if (_pendingRequests.isEmpty) return;

    _batchTimer?.cancel();
    _batchTimer = null;

    final batch = BatchRequest(
      requests: List.from(_pendingRequests),
      timeout: defaultTimeout,
      maxBatchSize: defaultMaxBatchSize,
    );

    _pendingRequests.clear();
    onBatchReady(batch);
  }

  /// Handle batch response
  void handleBatchResponse(BatchResponse response) {
    for (final responseItem in response.responses) {
      final id = responseItem['id'];
      final completer = _pendingCompleters.remove(id);

      if (completer != null && !completer.isCompleted) {
        if (responseItem['error'] != null) {
          completer.completeError(responseItem['error']);
        } else {
          completer.complete(responseItem['result']);
        }
      }
    }
  }

  /// Handle batch error (complete all pending requests with error)
  void handleBatchError(dynamic error) {
    for (final completer in _pendingCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingCompleters.clear();
  }

  /// Force send any pending batch
  void flush() {
    if (_pendingRequests.isNotEmpty) {
      _sendBatch();
    }
  }

  /// Dispose the batch manager
  void dispose() {
    _batchTimer?.cancel();

    // Complete any pending requests with error
    for (final completer in _pendingCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError('BatchManager disposed');
      }
    }
    _pendingCompleters.clear();
    _pendingRequests.clear();
  }
}

/// Batch-aware client transport wrapper
class BatchingClientTransport {
  final ClientTransport _underlying;
  final BatchManager _batchManager;
  final int maxBatchSize;
  final Duration batchTimeout;

  final StreamController<dynamic> _messageController =
      StreamController.broadcast();

  BatchingClientTransport(
    this._underlying, {
    this.maxBatchSize = 10,
    this.batchTimeout = const Duration(milliseconds: 100),
  }) : _batchManager = BatchManager(
         onBatchReady: (batch) => _underlying.send(batch.toJson()),
         defaultMaxBatchSize: maxBatchSize,
         defaultTimeout: batchTimeout,
       ) {
    // Listen for responses from underlying transport
    _underlying.onMessage.listen((message) {
      if (message is List) {
        // Batch response
        final batchResponse = BatchResponse.fromJson(message);
        _batchManager.handleBatchResponse(batchResponse);
      } else {
        // Single response - forward directly
        _messageController.add(message);
      }
    });
  }

  /// Stream of non-batched messages
  Stream<dynamic> get onMessage => _messageController.stream;

  /// Send a request (may be batched)
  Future<dynamic> sendRequest(Map<String, dynamic> request) {
    return _batchManager.addRequest(request);
  }

  /// Send a notification (not batched, sent immediately)
  void sendNotification(Map<String, dynamic> notification) {
    _underlying.send(notification);
  }

  /// Send a message directly without batching
  void sendDirect(dynamic message) {
    _underlying.send(message);
  }

  /// Flush any pending batches
  void flush() {
    _batchManager.flush();
  }

  /// Close the transport
  void close() {
    _batchManager.dispose();
    _underlying.close();
    _messageController.close();
  }
}

/// Utility functions for JSON-RPC batching
class BatchUtils {
  /// Check if a message is a valid JSON-RPC batch
  static bool isBatch(dynamic message) {
    return message is List && message.isNotEmpty;
  }

  /// Check if a request is batchable (has an ID)
  static bool isBatchable(Map<String, dynamic> request) {
    return request.containsKey('id') && request['id'] != null;
  }

  /// Check if a batch is valid
  static bool isValidBatch(List<dynamic> batch) {
    if (batch.isEmpty) return false;
    for (final item in batch) {
      if (item is! Map<String, dynamic>) return false;
      if (!item.containsKey('jsonrpc') || item['jsonrpc'] != '2.0') {
        return false;
      }
      if (!item.containsKey('method') || item['method'] is! String) {
        return false;
      }
    }
    return true;
  }

  /// Split a large batch into smaller batches
  static List<BatchRequest> splitBatch(
    BatchRequest largeBatch,
    int maxBatchSize,
  ) {
    final batches = <BatchRequest>[];
    final requests = largeBatch.requests;

    for (int i = 0; i < requests.length; i += maxBatchSize) {
      final end =
          (i + maxBatchSize < requests.length)
              ? i + maxBatchSize
              : requests.length;

      batches.add(
        BatchRequest(
          requests: requests.sublist(i, end),
          timeout: largeBatch.timeout,
          maxBatchSize: maxBatchSize,
        ),
      );
    }

    return batches;
  }

  /// Merge multiple batch responses
  static BatchResponse mergeBatchResponses(List<BatchResponse> responses) {
    final allResponses = <Map<String, dynamic>>[];

    for (final response in responses) {
      allResponses.addAll(response.responses);
    }

    return BatchResponse(responses: allResponses);
  }

  /// Create a batch request from individual requests
  static BatchRequest createBatch(
    List<Map<String, dynamic>> requests, {
    Duration? timeout,
    int? maxBatchSize,
  }) {
    return BatchRequest(
      requests: requests,
      timeout: timeout ?? const Duration(milliseconds: 100),
      maxBatchSize: maxBatchSize ?? 10,
    );
  }
}
