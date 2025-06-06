/// Streamable HTTP transport for MCP 2025-03-26
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../logger.dart';
import '../auth/oauth.dart';
import '../auth/oauth_client.dart';
import '../models/models.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_client.streamable_http_transport');

/// HTTP transport configuration
@immutable
class StreamableHttpTransportConfig {
  /// Base URL for the MCP server
  final String baseUrl;

  /// OAuth configuration (optional)
  final OAuthConfig? oauthConfig;

  /// Additional headers to send with requests
  final Map<String, String> headers;

  /// Request timeout
  final Duration timeout;

  /// SSE read timeout (longer for streaming)
  final Duration sseReadTimeout;

  /// Maximum number of concurrent requests
  final int maxConcurrentRequests;

  /// Whether to use HTTP/2 if available
  final bool useHttp2;

  /// Whether to terminate session on close
  final bool terminateOnClose;

  const StreamableHttpTransportConfig({
    required this.baseUrl,
    this.oauthConfig,
    this.headers = const {},
    this.timeout = const Duration(seconds: 30),
    this.sseReadTimeout = const Duration(minutes: 5),
    this.maxConcurrentRequests = 10,
    this.useHttp2 = true,
    this.terminateOnClose = true,
  });
}

/// Streamable HTTP client transport for MCP
class StreamableHttpClientTransport implements ClientTransport {
  final StreamableHttpTransportConfig config;
  final http.Client _httpClient;
  final HttpOAuthClient? _oauthClient;
  final OAuthTokenManager? _tokenManager;

  final StreamController<dynamic> _messageController =
      StreamController.broadcast();
  final Completer<void> _closeCompleter = Completer<void>();

  bool _isClosed = false;
  final Semaphore _requestSemaphore;
  String? _sessionId;
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  HttpClient? _sseClient;
  HttpClientRequest? _sseRequest;
  HttpClientResponse? _sseResponse;
  StreamSubscription? _sseSubscription;
  final StringBuffer _sseBuffer = StringBuffer();
  bool _getStreamActive = false;

  StreamableHttpClientTransport._({
    required this.config,
    required http.Client httpClient,
    HttpOAuthClient? oauthClient,
    OAuthTokenManager? tokenManager,
  }) : _httpClient = httpClient,
       _oauthClient = oauthClient,
       _tokenManager = tokenManager,
       _requestSemaphore = Semaphore(config.maxConcurrentRequests);

  /// Create a new Streamable HTTP transport
  static Future<StreamableHttpClientTransport> create({
    required String baseUrl,
    OAuthConfig? oauthConfig,
    Map<String, String>? headers,
    Duration? timeout,
    int? maxConcurrentRequests,
    bool? useHttp2,
    http.Client? httpClient,
  }) async {
    final config = StreamableHttpTransportConfig(
      baseUrl: baseUrl,
      oauthConfig: oauthConfig,
      headers: headers ?? const {},
      timeout: timeout ?? const Duration(seconds: 30),
      maxConcurrentRequests: maxConcurrentRequests ?? 10,
      useHttp2: useHttp2 ?? true,
    );

    final client =
        httpClient ??
        (config.useHttp2
            ? http.Client()
            : // Use default client
            http.Client());

    HttpOAuthClient? oauthClient;
    OAuthTokenManager? tokenManager;

    if (oauthConfig != null) {
      oauthClient = HttpOAuthClient(config: oauthConfig, httpClient: client);
      tokenManager = OAuthTokenManager(oauthClient);
    }

    return StreamableHttpClientTransport._(
      config: config,
      httpClient: client,
      oauthClient: oauthClient,
      tokenManager: tokenManager,
    );
  }

  @override
  Stream<dynamic> get onMessage => _messageController.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  /// Get the base URL
  String get baseUrl => config.baseUrl;

  /// Get the maximum concurrent requests
  int get maxConcurrentRequests => config.maxConcurrentRequests;

  /// Check if HTTP/2 is enabled
  bool get useHttp2 => config.useHttp2;

  /// Get the OAuth configuration
  OAuthConfig? get oauthConfig => config.oauthConfig;

  /// Get the current session ID
  String? get sessionId => _sessionId;

  /// Send a JSON-RPC message
  @override
  void send(dynamic message) {
    if (_isClosed) return;

    // Check if this is the initialized notification
    if (message is Map &&
        message['method'] == 'notifications/initialized' &&
        !_getStreamActive) {
      _startGetStream();
    }

    _sendRequest(message).catchError((error) {
      _messageController.addError(error);
    });
  }

  /// Send HTTP request with proper authentication
  Future<void> _sendRequest(dynamic message) async {
    await _requestSemaphore.acquire();

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        // StreamableHTTP standard requires accepting both content types
        'Accept': 'application/json, text/event-stream',
        ...config.headers,
      };

      // Add session ID if available
      if (_sessionId != null) {
        headers['MCP-Session-Id'] = _sessionId!;
      }

      // Add OAuth token if available
      if (_tokenManager != null) {
        try {
          final token = await _tokenManager.getAccessToken();
          headers['Authorization'] = 'Bearer $token';
        } on OAuthError catch (e) {
          if (e.error == 'no_valid_token') {
            // Send 401 to trigger OAuth flow
            _messageController.add({
              'jsonrpc': '2.0',
              'error': {
                'code': -32001,
                'message': 'Authentication required',
                'data': {'oauth_error': e.toJson()},
              },
              if (message is Map && message['id'] != null) 'id': message['id'],
            });
            return;
          }
          rethrow;
        }
      }

      final body = jsonEncode(message);
      final uri = Uri.parse(config.baseUrl);

      // Store request ID if this is a request
      int? requestId;
      if (message is Map && message['id'] != null) {
        requestId = message['id'] as int;
        _pendingRequests[requestId] = Completer<dynamic>();
      }

      final response = await _httpClient
          .post(uri, headers: headers, body: body)
          .timeout(config.timeout);

      // Extract session ID from response headers
      final newSessionId = response.headers['mcp-session-id'];
      if (newSessionId != null && newSessionId != _sessionId) {
        _sessionId = newSessionId;
        _logger.debug('Received session ID: $_sessionId');
      }

      if (response.statusCode == 202) {
        // 202 Accepted - no immediate response expected
        _logger.debug('Received 202 Accepted');
        return;
      }

      if (response.statusCode == 404) {
        // Session terminated
        if (requestId != null) {
          _messageController.add({
            'jsonrpc': '2.0',
            'id': requestId,
            'error': {'code': 32600, 'message': 'Session terminated'},
          });
        }
        return;
      }

      if (response.statusCode == 401) {
        // Authentication required - trigger OAuth flow
        _messageController.add({
          'jsonrpc': '2.0',
          'error': {
            'code': -32001,
            'message': 'Authentication required',
            'data': {
              'www_authenticate': response.headers['www-authenticate'],
              'oauth_config_hint': config.oauthConfig?.toJson(),
            },
          },
          if (requestId != null) 'id': requestId,
        });
        return;
      }

      if (response.statusCode >= 400) {
        throw HttpException(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}',
          uri: uri,
        );
      }

      // Check content type
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';

      if (contentType.startsWith('application/json')) {
        // Direct JSON response - decode bytes with UTF-8
        final responseBytes = response.bodyBytes;
        if (responseBytes.isNotEmpty) {
          final responseBody = utf8.decode(responseBytes);
          final responseMessage = jsonDecode(responseBody);
          _messageController.add(responseMessage);
        }
      } else if (contentType.startsWith('text/event-stream')) {
        // SSE response - handle streaming
        await _handleSseResponse(response, requestId);
      } else {
        _logger.warning('Unexpected content type: $contentType');
        // Try to parse as JSON anyway - use bytes for UTF-8 safety
        final responseBytes = response.bodyBytes;
        if (responseBytes.isNotEmpty) {
          try {
            final responseBody = utf8.decode(responseBytes);
            final responseMessage = jsonDecode(responseBody);
            _messageController.add(responseMessage);
          } catch (e) {
            _logger.error('Failed to parse response: $e');
          }
        }
      }
    } finally {
      _requestSemaphore.release();
    }
  }

  /// Handle SSE response from POST request
  Future<void> _handleSseResponse(
    http.Response response,
    int? requestId,
  ) async {
    _logger.debug('Handling SSE response');
    // Use bodyBytes for proper UTF-8 handling
    final bytes = response.bodyBytes;
    if (bytes.isNotEmpty) {
      try {
        final body = utf8.decode(bytes);
        // Try to extract JSON from SSE data
        final lines = body.split('\n');
        for (final line in lines) {
          if (line.startsWith('data:')) {
            final data = line.substring(5).trim();
            if (data.isNotEmpty && data != '[DONE]') {
              try {
                final json = jsonDecode(data);
                _messageController.add(json);
              } catch (e) {
                _logger.debug('Failed to parse SSE data: $data');
              }
            }
          }
        }
      } catch (e) {
        _logger.error('Error parsing SSE response: $e');
      }
    }
  }

  /// Start GET stream for server-initiated messages
  void _startGetStream() {
    if (_getStreamActive || _sessionId == null) return;

    _getStreamActive = true;
    _logger.debug('Starting GET stream for session: $_sessionId');

    _establishGetStream().catchError((error) {
      _logger.error('GET stream error: $error');
      _getStreamActive = false;
    });
  }

  /// Establish SSE GET stream
  Future<void> _establishGetStream() async {
    try {
      _sseClient = HttpClient();
      final uri = Uri.parse(config.baseUrl);
      _sseRequest = await _sseClient!.getUrl(uri);

      // Set headers
      _sseRequest!.headers.set('Accept', 'text/event-stream');
      _sseRequest!.headers.set('Cache-Control', 'no-cache');
      if (_sessionId != null) {
        _sseRequest!.headers.set('MCP-Session-Id', _sessionId!);
      }
      config.headers.forEach((key, value) {
        _sseRequest!.headers.set(key, value);
      });

      // Add OAuth token if available
      if (_tokenManager != null) {
        try {
          final token = await _tokenManager.getAccessToken();
          _sseRequest!.headers.set('Authorization', 'Bearer $token');
        } catch (e) {
          _logger.debug('Failed to add OAuth token to GET stream: $e');
        }
      }

      _sseResponse = await _sseRequest!.close();

      if (_sseResponse!.statusCode != 200) {
        final body = await _sseResponse!.transform(utf8.decoder).join();
        throw McpError(
          'Failed to establish GET stream: ${_sseResponse!.statusCode} - $body',
        );
      }

      _logger.debug('GET SSE connection established');

      // Set up subscription to process events
      _sseSubscription = _sseResponse!.listen(
        (List<int> data) {
          try {
            final chunk = utf8.decode(data, allowMalformed: true);
            _sseBuffer.write(chunk);
            _processSseBuffer();
          } catch (e) {
            _logger.error('Error processing SSE data: $e');
          }
        },
        onError: (error) {
          _logger.error('GET stream error: $error');
          _getStreamActive = false;
        },
        onDone: () {
          _logger.debug('GET stream closed');
          _getStreamActive = false;
        },
      );
    } catch (e) {
      _logger.error('Failed to establish GET stream: $e');
      _getStreamActive = false;
      rethrow;
    }
  }

  /// Process SSE buffer for events
  void _processSseBuffer() {
    final content = _sseBuffer.toString();
    if (content.isEmpty) return;

    // Split by double newline to find complete events
    final eventBlocks = content.split(RegExp(r'(\r?\n){2}'));

    if (eventBlocks.length < 2) {
      // No complete event yet
      return;
    }

    // Process complete events
    for (int i = 0; i < eventBlocks.length - 1; i++) {
      final eventBlock = eventBlocks[i];
      if (eventBlock.isEmpty) continue;

      final lines = eventBlock.split(RegExp(r'\r?\n'));
      String? eventType;
      String? eventData;

      for (final line in lines) {
        if (line.startsWith('event:')) {
          eventType = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          eventData = line.substring(5).trim();
        } else if (line.startsWith('id:')) {
          // eventId = line.substring(3).trim();
          // TODO: Implement resumption token handling
        }
      }

      if (eventType == 'message' && eventData != null) {
        try {
          final message = jsonDecode(eventData);
          _logger.debug('Received SSE message: $message');
          _messageController.add(message);
        } catch (e) {
          _logger.error('Failed to parse SSE message: $e');
        }
      }
    }

    // Keep the incomplete last block in buffer
    _sseBuffer.clear();
    if (eventBlocks.isNotEmpty) {
      _sseBuffer.write(eventBlocks.last);
    }
  }

  @override
  void close() {
    if (_isClosed) return;
    _isClosed = true;

    // Terminate session if configured
    if (config.terminateOnClose && _sessionId != null) {
      _terminateSession().catchError((error) {
        _logger.debug('Failed to terminate session: $error');
      });
    }

    // Close GET stream
    _sseSubscription?.cancel();
    _sseClient?.close(force: true);

    // Complete pending requests with error
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(McpError('Transport closed'));
      }
    }
    _pendingRequests.clear();

    _messageController.close();
    _httpClient.close();
    _oauthClient?.close();
    _tokenManager?.dispose();

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }

  /// Terminate the session
  Future<void> _terminateSession() async {
    if (_sessionId == null) return;

    try {
      final headers = <String, String>{
        'MCP-Session-Id': _sessionId!,
        ...config.headers,
      };

      final uri = Uri.parse(config.baseUrl);
      final response = await _httpClient
          .delete(uri, headers: headers)
          .timeout(Duration(seconds: 5));

      if (response.statusCode == 405) {
        _logger.debug('Server does not allow session termination');
      } else if (response.statusCode != 200 && response.statusCode != 204) {
        _logger.warning('Session termination failed: ${response.statusCode}');
      }
    } catch (e) {
      _logger.warning('Session termination failed: $e');
    }
  }

  /// Initiate OAuth authentication flow
  Future<OAuthToken> authenticateWithOAuth({
    required List<String> scopes,
    String? state,
  }) async {
    if (_oauthClient == null) {
      throw StateError('OAuth not configured for this transport');
    }

    final authUrl = await _oauthClient.getAuthorizationUrl(
      scopes: scopes,
      state: state,
    );

    // In a real implementation, you would:
    // 1. Open the auth URL in a browser
    // 2. Handle the redirect
    // 3. Extract the authorization code
    // 4. Exchange it for a token

    throw UnimplementedError(
      'OAuth flow requires platform-specific implementation. '
      'Authorization URL: $authUrl',
    );
  }

  /// Set OAuth token manually
  void setOAuthToken(OAuthToken token) {
    _tokenManager?.setToken(token);
  }
}

/// Semaphore for controlling concurrent requests
class Semaphore {
  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  Semaphore(this.maxCount) : _currentCount = maxCount;

  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}
