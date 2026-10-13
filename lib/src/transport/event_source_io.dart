import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../logger.dart';
import '../models/models.dart';
import 'event_source_stub.dart' as stub;
import 'sse_parser.dart';

final Logger _logger = Logger('mcp_client.event_source_io');

/// Native platform EventSource implementation using HttpClient
class EventSource implements stub.EventSource {
  HttpClient? _client;
  HttpClientRequest? _request;
  HttpClientResponse? _response;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  bool _closing = false;

  EventSource();

  @override
  bool get isConnected => _isConnected;

  @override
  HttpClientResponse? get response => _response;

  @override
  Future<void> connect(
    String url, {
    Map<String, String>? headers,
    Function(String?)? onOpen,
    Function(dynamic)? onMessage,
    Function(dynamic)? onError,
    Function(String?)? onEndpoint,
  }) async {
    _logger.debug('EventSource connecting');
    if (_isConnected) {
      throw McpError('EventSource is already connected');
    }

    try {
      // Initialize connection
      _client = HttpClient();
      _request = await _client!.getUrl(Uri.parse(url));

      // Set up MCP standard SSE headers
      _request!.headers.set('Accept', 'text/event-stream');
      _request!.headers.set('Cache-Control', 'no-cache');
      _request!.headers.set(
        'Accept-Encoding',
        'identity',
      ); // Disable compression
      if (headers != null) {
        headers.forEach((key, value) {
          _request!.headers.set(key, value);
        });
      }

      _response = await _request!.close();

      if (_response!.statusCode != 200) {
        final body = await _response!.transform(utf8.decoder).join();
        throw McpError(
          'Failed to connect to SSE endpoint: ${_response!.statusCode} - $body',
        );
      }

      _isConnected = true;
      _logger.debug('EventSource connection established');

      // Events, parsed as the SSE format defines them.
      _subscription = _response!
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .transform(const SseParser())
          .listen(
        (event) {
          switch (event.event) {
            case 'endpoint':
              onEndpoint?.call(event.data);
            case 'open':
              onOpen?.call(event.data);
            case 'error':
              onError?.call(event.data);
            default:
              if (event.data.isEmpty) return; // priming event
              try {
                onMessage?.call(jsonDecode(event.data));
              } on FormatException {
                _logger.debug('Ignoring an SSE event that is not JSON');
              }
          }
        },
        onError: (Object error) {
          _isConnected = false;
          if (_closing) return;
          _logger.error('EventSource stream error: $error');
          onError?.call(error);
        },
        onDone: () {
          _logger.debug('EventSource stream closed');
          _isConnected = false;
        },
      );
    } catch (e) {
      _logger.error('Failed to connect EventSource: $e');
      _isConnected = false;
      if (onError != null) {
        onError(e);
      }
      rethrow;
    }
  }

  @override
  void close() {
    _logger.debug('Closing EventSource');
    _isConnected = false;
    _closing = true;
    // Closing the client aborts the response; that error is expected now.
    _subscription?.cancel().catchError((Object _) {});
    _client?.close(force: true);
  }
}
