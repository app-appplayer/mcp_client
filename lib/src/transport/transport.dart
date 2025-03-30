import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../../logger.dart';
import '../models/models.dart';

/// Abstract base class for client transport implementations
abstract class ClientTransport {
  /// Stream of incoming messages
  Stream<dynamic> get onMessage;

  /// Future that completes when the transport is closed
  Future<void> get onClose;

  /// Send a message through the transport
  void send(dynamic message);

  /// Close the transport
  void close();
}

/// Transport implementation using standard input/output streams
class StdioClientTransport implements ClientTransport {
  final Process _process;
  final _messageController = StreamController<dynamic>.broadcast();
  final List<StreamSubscription> _processSubscriptions = [];
  final _closeCompleter = Completer<void>();

  // Message queue for synchronized sending
  final _messageQueue = Queue<String>();
  bool _isSending = false;

  StdioClientTransport._internal(this._process) {
    _initialize();
  }

  /// Create a new STDIO transport by spawning a process
  static Future<StdioClientTransport> create({
    required String command,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    log.debug('[MCP Client] Starting process: $command ${arguments.join(' ')}');

    final process = await Process.start(
      command,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );

    return StdioClientTransport._internal(process);
  }

  void _initialize() {
    log.debug('[MCP Client] Initializing STDIO transport');

    // Process stdout stream and handle messages
    var stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .map((line) {
      try {
        log.debug('[MCP Client] Raw received line: $line');
        final parsedMessage = jsonDecode(line);
        log.debug('[MCP Client] Parsed message: $parsedMessage');
        return parsedMessage;
      } catch (e) {
        log.debug('[MCP Client] JSON parsing error: $e');
        log.debug('[MCP Client] Problematic line: $line');
        return null;
      }
    })
        .where((message) => message != null)
        .listen(
          (message) {
            log.debug('[MCP Client] Processing message: $message');
        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
      },
      onError: (error) {
        log.debug('[MCP Client] Stream error: $error');
        _handleTransportError(error);
      },
      onDone: () {
        log.debug('[MCP Client] stdout stream done');
        _handleStreamClosure();
      },
      cancelOnError: false,
    );

    // Store subscription for cleanup
    _processSubscriptions.add(stdoutSubscription);

    // Log stderr output
    var stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      log.debug('[MCP Client] Server stderr: $line');
    });

    _processSubscriptions.add(stderrSubscription);

    // Handle process exit
    _process.exitCode.then((exitCode) {
      log.debug('[MCP Client] Process exited with code: $exitCode');
      _handleStreamClosure();
    });
  }

  void _handleTransportError(dynamic error) {
    log.debug('[MCP Client] Transport error: $error');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
    _cleanup();
  }

  void _handleStreamClosure() {
    log.debug('[MCP Client] Handling stream closure');
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
    _cleanup();
  }

  void _cleanup() {
    // Cancel all subscriptions
    for (var subscription in _processSubscriptions) {
      subscription.cancel();
    }
    _processSubscriptions.clear();

    if (!_messageController.isClosed) {
      _messageController.close();
    }

    // Ensure the process is terminated
    try {
      _process.kill();
    } catch (e) {
      // Process might already be terminated
      log.debug('[MCP Client] Error killing process: $e');
    }
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  // Add message to queue and process it
  @override
  void send(dynamic message) {
    try {
      final jsonMessage = jsonEncode(message);
      log.debug('[MCP Client] Queueing message: $jsonMessage');

      // Add message to queue
      _messageQueue.add(jsonMessage);

      // Start processing queue if not already doing so
      _processMessageQueue();
    } catch (e) {
      log.debug('[MCP Client] Error encoding message: $e');
      log.debug('[MCP Client] Original message: $message');
      rethrow;
    }
  }

  // Process messages in queue one at a time
  void _processMessageQueue() {
    if (_isSending || _messageQueue.isEmpty) {
      return;
    }

    _isSending = true;

    // Process all messages in queue
    _sendNextMessage();
  }

  void _sendNextMessage() {
    if (_messageQueue.isEmpty) {
      _isSending = false;
      return;
    }

    final message = _messageQueue.removeFirst();

    try {
      log.debug('[MCP Client] Sending message: $message');
      _process.stdin.writeln(message);

      // Use Timer to give stdin a chance to process
      Timer(Duration(milliseconds: 10), () {
        log.debug('[MCP Client] Message sent successfully');
        _sendNextMessage();
      });
    } catch (e) {
      log.debug('[MCP Client] Error sending message: $e');
      _isSending = false;
      throw Exception('Failed to write to process stdin: $e');
    }
  }

  @override
  void close() {
    log.debug('[MCP Client] Closing StdioClientTransport');
    _cleanup();
  }
}

/// Transport implementation using Server-Sent Events (SSE) over HTTP
class SseClientTransport implements ClientTransport {
  final String serverUrl;
  final Map<String, String>? headers;
  final _messageController = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final EventSource _eventSource = EventSource();
  String? _messageEndpoint;
  StreamSubscription? _subscription;

  // Private constructor
  SseClientTransport._internal({
    required this.serverUrl,
    this.headers,
  });

  // Factory method for creation
  static Future<SseClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
  }) async {
    final transport = SseClientTransport._internal(
      serverUrl: serverUrl,
      headers: headers,
    );

    try {
      // Set up event handlers
      final endpointCompleter = Completer<String>();

      await transport._eventSource.connect(
          serverUrl,
          headers: headers,
          onOpen: (endpoint) {
            if (!endpointCompleter.isCompleted && endpoint != null) {
              endpointCompleter.complete(endpoint);
            }
          },
          onMessage: (data) {
            // This is crucial - forward messages to the controller
            if (data is Map && data.containsKey('jsonrpc') &&
                data.containsKey('id') && !transport._messageController.isClosed) {
              log.debug('[MCP Client] Forwarding JSON-RPC response: $data');
              transport._messageController.add(data);
            } else if (!transport._messageController.isClosed) {
              transport._messageController.add(data);
            }
          },
          onError: (e) {
            log.debug('[MCP Client] SSE error: $e');
            if (!endpointCompleter.isCompleted) {
              endpointCompleter.completeError(e);
            }
            transport._handleError(e);
          }
      );

      // Wait for endpoint
      final endpointPath = await endpointCompleter.future.timeout(
          Duration(seconds: 10),
          onTimeout: () => throw McpError('Timed out waiting for endpoint')
      );

      // Set up message endpoint
      final baseUrl = Uri.parse(serverUrl);
      transport._messageEndpoint = transport._constructEndpointUrl(baseUrl, endpointPath);
      log.debug('[MCP Client] Transport ready with endpoint: ${transport._messageEndpoint}');

      return transport;
    } catch (e) {
      transport.close();
      throw McpError('Failed to establish SSE connection: $e');
    }
  }


  // Helper method to construct endpoint URL
  String _constructEndpointUrl(Uri baseUrl, String endpointPath) {
    try {
      final Uri endpointUri;
      if (endpointPath.contains('?')) {
        final parts = endpointPath.split('?');
        endpointUri = Uri(
            path: parts[0],
            query: parts.length > 1 ? parts[1] : null
        );
      } else {
        endpointUri = Uri(path: endpointPath);
      }

      return Uri(
          scheme: baseUrl.scheme,
          host: baseUrl.host,
          port: baseUrl.port,
          path: endpointUri.path,
          query: endpointUri.query
      ).toString();
    } catch (e) {
      log.debug('[MCP Client] Error parsing endpoint URL: $e');
      // Fallback to simple concatenation
      return '${baseUrl.origin}$endpointPath';
    }
  }

  void _handleError(dynamic error) {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
  }

  // Standard interface methods
  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) async {
    if (_messageEndpoint == null) {
      throw McpError('Cannot send message: SSE connection not fully established');
    }

    try {
      final jsonMessage = jsonEncode(message);
      log.debug('[MCP Client] Sending message: $jsonMessage');

      final url = Uri.parse(_messageEndpoint!);
      final client = HttpClient();
      final request = await client.postUrl(url);

      // Set headers
      request.headers.contentType = ContentType.json;
      if (headers != null) {
        headers!.forEach((name, value) {
          request.headers.add(name, value);
        });
      }

      // Send the request
      request.write(jsonMessage);
      final response = await request.close();

      // Just check for successful delivery
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        log.debug('[MCP Client] Message delivery confirmation: $responseBody');
        // Don't forward this to message controller, actual response comes via SSE
      } else {
        final responseBody = await response.transform(utf8.decoder).join();
        log.debug('[MCP Client] Error response: $responseBody');
        throw McpError('Error sending message: ${response.statusCode}');
      }

      // Close the HTTP client
      client.close();
      log.debug('[MCP Client] Message sent successfully');
    } catch (e) {
      log.debug('[MCP Client] Error sending message: $e');
      rethrow;
    }
  }

  @override
  void close() {
    log.debug('[MCP Client] Closing SseClientTransport');
    _subscription?.cancel();
    _eventSource.close();
    if (!_messageController.isClosed) {
      _messageController.close();
    }
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }
}

/// EventSource implementation for SSE
class EventSource {
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _subscription;
  final _buffer = StringBuffer();
  bool _isConnected = false;

  bool get isConnected => _isConnected;
  HttpClientResponse? get response => _response; // Added getter to access response

  Future<void> connect(
      String url, {
        Map<String, String>? headers,
        Function(String?)? onOpen,
        Function(dynamic)? onMessage,
        Function(dynamic)? onError,
      }) async {
    log.debug('[MCP Client] EventSource connecting');
    if (_isConnected) {
      throw McpError('EventSource is already connected');
    }

    try {
      // Initialize connection
      _client = HttpClient();
      _request = await _client!.getUrl(Uri.parse(url));

      // Set up SSE headers
      _request!.headers.set('Accept', 'text/event-stream');
      _request!.headers.set('Cache-Control', 'no-cache');
      if (headers != null) {
        headers.forEach((key, value) {
          _request!.headers.set(key, value);
        });
      }

      _response = await _request!.close();

      if (_response!.statusCode != 200) {
        final body = await _response!.transform(utf8.decoder).join();
        throw McpError('Failed to connect to SSE endpoint: ${_response!.statusCode} - $body');
      }

      _isConnected = true;
      log.debug('[MCP Client] EventSource connection established');

      // Set up subscription to process events
      _subscription = _response!.transform(utf8.decoder).listen(
              (chunk) {
            // Log raw data for debugging
            log.debug('[MCP Client] Raw SSE data: $chunk');
            _buffer.write(chunk);

            // Process all events in buffer
            final content = _buffer.toString();

            // Simple check for JSON-RPC responses
            if (content.contains('"jsonrpc":"2.0"') || content.contains('"jsonrpc": "2.0"')) {
              log.debug('[MCP Client] Detected JSON-RPC data in SSE stream');

              try {
                // Try to extract JSON objects from the stream
                final jsonStart = content.indexOf('{');
                final jsonEnd = content.lastIndexOf('}') + 1;

                if (jsonStart >= 0 && jsonEnd > jsonStart) {
                  final jsonStr = content.substring(jsonStart, jsonEnd);
                  log.debug('[MCP Client] Extracted JSON: $jsonStr');

                  try {
                    final jsonData = jsonDecode(jsonStr);
                    log.debug('[MCP Client] Parsed JSON-RPC data: $jsonData');

                    // Clear the processed part from buffer
                    if (jsonEnd < content.length) {
                      _buffer.clear();
                      _buffer.write(content.substring(jsonEnd));
                    } else {
                      _buffer.clear();
                    }

                    // Forward to message handler
                    if (onMessage != null) {
                      onMessage(jsonData);
                    }
                    return; // Processed JSON data
                  } catch (e) {
                    log.debug('[MCP Client] JSON parse error: $e');
                  }
                }
              } catch (e) {
                log.debug('[MCP Client] Error extracting JSON: $e');
              }
            }

            // If no JSON-RPC data found, try regular SSE event processing
            final event = _processBuffer();

            if (event.event == 'endpoint' && event.data != null && onOpen != null) {
              // Handle endpoint event
              onOpen(event.data);
            } else if (event.data != null && onMessage != null) {
              onMessage(event.data);
            }
          },
          onError: (e) {
            log.debug('[MCP Client] EventSource error: $e');
            _isConnected = false;
            if (onError != null) {
              onError(e);
            }
          },
          onDone: () {
            log.debug('[MCP Client] EventSource stream closed');
            _isConnected = false;
            if (onError != null) {
              onError('Connection closed');
            }
          }
      );
    } catch (e) {
      log.debug('[MCP Client] EventSource connection error: $e');
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  // Process the buffer to find SSE events
  _SseEvent _processBuffer() {
    final lines = _buffer.toString().split('\n');
    log.debug('[MCP Client] _processBuffer lines count: ${lines.length}');

    String currentEvent = '';
    String? currentData;
    bool isCheckedType = false;
    bool isCheckedData = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('event:') && !isCheckedType) {
        currentEvent = line.substring(6).trim();
        isCheckedType = true;
        log.debug('[MCP Client] Found event type: $currentEvent');
      }
      else if (line.startsWith('data:') && !isCheckedData) {
        currentData = line.substring(5).trim();
        isCheckedData = true;
        log.debug('[MCP Client] Found event data: $currentData');
      }

      if(isCheckedType && isCheckedData) {
        log.debug('[MCP Client] Creating event: $currentEvent, data: $currentData');
        return _SseEvent(currentEvent, currentData);
      }
    }

    // Return empty event if no complete event found
    return _SseEvent('', null);
  }

  void close() {
    log.debug('[MCP Client] Closing EventSource');
    _subscription?.cancel();
    _client?.close();
    _isConnected = false;
  }
}

class _SseEvent {
  final String event;
  final String? data;

  _SseEvent(this.event, this.data);
}