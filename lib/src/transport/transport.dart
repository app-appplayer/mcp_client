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
  final _eventSource = EventSource();
  String? _messageEndpoint;

  SseClientTransport({
    required this.serverUrl,
    this.headers,
  }) {
    _initialize();
  }

  void _initialize() async {
    try {
      await _eventSource.connect(
        serverUrl,
        headers: headers,
        onOpen: _handleOpen,
        onMessage: _handleServerMessage,
        onError: _handleError,
      );
    } catch (e) {
      _handleTransportError(e);
    }
  }

  void _handleOpen(String? endpointUrl) {
    log.debug('[MCP Client] SSE connection opened');
    _messageEndpoint = endpointUrl;
  }

  void _handleServerMessage(dynamic data) {
    try {
      log.debug('[MCP Client] Received SSE message: $data');
      final jsonData = jsonDecode(data);
      _messageController.add(jsonData);
    } catch (e) {
      log.debug('[MCP Client] Error parsing SSE message: $e');
    }
  }

  void _handleError(dynamic error) {
    log.debug('[MCP Client] SSE error: $error');
    _handleTransportError(error);
  }

  void _handleTransportError(dynamic error) {
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.completeError(error);
    }
    _cleanup();
  }

  void _cleanup() {
    _eventSource.close();
    if (!_messageController.isClosed) {
      _messageController.close();
    }
  }

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

      request.headers.contentType = ContentType.json;
      if (headers != null) {
        headers!.forEach((name, value) {
          request.headers.add(name, value);
        });
      }

      request.write(jsonMessage);
      final response = await request.close();

      if (response.statusCode != 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        log.debug('[MCP Client] Error response: $responseBody');
        throw McpError('Error sending message: ${response.statusCode}');
      }

      client.close();
      log.debug('[MCP Client] Message sent successfully');
    } catch (e) {
      log.debug('[MCP Client] Error sending message: $e');
      log.debug('[MCP Client] Original message: $message');
      rethrow;
    }
  }

  @override
  void close() {
    log.debug('[MCP Client] Closing SseClientTransport');
    _cleanup();
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

  Future<void> connect(
      String url, {
        Map<String, String>? headers,
        Function(String?)? onOpen,
        Function(dynamic)? onMessage,
        Function(dynamic)? onError,
      }) async {
    if (_isConnected) {
      throw McpError('EventSource is already connected');
    }

    try {
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

      // Process the 'endpoint' event first
      String? messageEndpoint;
      await for (final chunk in _response!.transform(utf8.decoder)) {
        _buffer.write(chunk);
        final events = _processBuffer();

        for (final event in events) {
          if (event.event == 'endpoint' && event.data != null) {
            final baseUrl = Uri.parse(url);
            final endpointPath = event.data;
            final endpointUrl = Uri(
              scheme: baseUrl.scheme,
              host: baseUrl.host,
              port: baseUrl.port,
              path: endpointPath,
            ).toString();

            messageEndpoint = endpointUrl;
            if (onOpen != null) {
              onOpen(messageEndpoint);
            }
            break;
          }
        }

        if (messageEndpoint != null) {
          break;
        }
      }

      // Continue processing events
      _subscription = _response!.transform(utf8.decoder).listen(
            (chunk) {
          _buffer.write(chunk);
          final events = _processBuffer();

          for (final event in events) {
            if (event.event == 'message' && onMessage != null) {
              onMessage(event.data);
            }
          }
        },
        onError: (error) {
          _isConnected = false;
          if (onError != null) {
            onError(error);
          }
        },
        onDone: () {
          _isConnected = false;
          if (onError != null) {
            onError('Connection closed');
          }
        },
      );
    } catch (e) {
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  List<_SseEvent> _processBuffer() {
    final events = <_SseEvent>[];
    final lines = _buffer.toString().split('\n');

    int i = 0;
    while (i < lines.length) {
      String event = 'message';
      String? data;

      // Process event
      while (i < lines.length && lines[i].isNotEmpty) {
        final line = lines[i];
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          data = line.substring(5).trim();
        }
        i++;
      }

      if (data != null) {
        events.add(_SseEvent(event, data));
      }

      // Skip empty lines
      while (i < lines.length && lines[i].isEmpty) {
        i++;
      }
    }

    // Clear processed lines
    if (lines.length > 1) {
      final remaining = lines.last.isEmpty ? '' : lines.last;
      _buffer.clear();
      _buffer.write(remaining);
    }

    return events;
  }

  void close() {
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