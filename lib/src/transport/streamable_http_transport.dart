/// Streamable HTTP transport for MCP 2025-03-26
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../logger.dart';
import '../auth/mcp_oauth.dart';
import '../auth/oauth.dart';
import '../auth/oauth_discovery.dart';
import '../models/models.dart';
import '../protocol/protocol.dart';
import 'sse_parser.dart';
import 'transport.dart';

final Logger _logger = Logger('mcp_client.streamable_http_transport');

/// Supplies headers for one outbound request.
///
/// Called per request, which is the point: [StreamableHttpTransportConfig.headers]
/// is fixed when the transport is built, so anything that expires — an
/// attestation token, a short-lived session credential — cannot live there. A
/// host that has to *fetch* the value at call time needs this instead.
///
/// Receives the request being made so one provider can serve several
/// transports and decide per destination.
///
/// Whatever it returns is added to the request, except the names the protocol
/// owns (see [reservedHeaderNames]). Those are dropped rather than honoured: a
/// supplied `MCP-Session-Id` or `Content-Type` would break the exchange in a
/// way that looks like a server fault.
typedef RequestHeadersProvider = FutureOr<Map<String, String>> Function(
  ({String url, String method}) request,
);

/// Header names a provider may not set, because the transport's correctness
/// depends on them.
const Set<String> reservedHeaderNames = <String>{
  'content-type',
  'accept',
  'mcp-session-id',
  'mcp-protocol-version',
  'mcp-method',
  'mcp-name',
  'last-event-id',
};

/// HTTP transport configuration
@immutable
class StreamableHttpTransportConfig {
  /// Base URL for the MCP server
  final String baseUrl;

  /// MCP authorization (optional): its token goes on every request, and a
  /// 401 / 403 challenge is answered through it before the request is
  /// retried once.
  final McpOAuth? oauth;

  /// Additional headers to send with requests.
  ///
  /// Fixed for the life of the transport. For a value that changes or expires,
  /// use [headersProvider].
  final Map<String, String> headers;

  /// Asked for headers on every request. See [RequestHeadersProvider].
  ///
  /// A provider that throws, or takes longer than [headersProviderTimeout],
  /// contributes nothing and the request is sent without its headers. The
  /// alternative — failing the request — would report a hook problem as an
  /// unreachable server, and send whoever is looking at the screen to check
  /// their network for something that is not there. What the origin then says
  /// about the missing credential is the accurate answer, and it comes from
  /// the origin.
  final RequestHeadersProvider? headersProvider;

  /// How long a provider may take before the request proceeds without it.
  ///
  /// A hang is worse than a failure: it has no error to report and no end.
  final Duration headersProviderTimeout;

  /// Request timeout
  final Duration timeout;

  /// SSE read timeout (longer for streaming)
  final Duration sseReadTimeout;

  /// Maximum number of concurrent requests
  final int maxConcurrentRequests;

  /// No effect: the HTTP client used here speaks HTTP/1.1. Kept so 2.x
  /// calls compile; pass an HTTP/2-capable `http.Client` as `httpClient`
  /// to use HTTP/2.
  @Deprecated('No effect: pass an HTTP/2-capable http.Client as httpClient')
  final bool useHttp2;

  /// Whether to terminate session on close
  final bool terminateOnClose;

  const StreamableHttpTransportConfig({
    required this.baseUrl,
    this.oauth,
    this.headers = const {},
    this.headersProvider,
    this.headersProviderTimeout = const Duration(seconds: 5),
    this.timeout = const Duration(seconds: 30),
    this.sseReadTimeout = const Duration(minutes: 5),
    this.maxConcurrentRequests = 10,
    this.useHttp2 = true,
    this.terminateOnClose = true,
  });
}

/// Streamable HTTP client transport for MCP
/// Operations whose target name is mirrored into `Mcp-Name` (2026-07-28;
/// the tasks extension adds the task operations, named by `taskId`).
const Set<String> _methodsRequiringName = {
  'tools/call',
  'resources/read',
  'prompts/get',
  'tasks/get',
  'tasks/update',
  'tasks/cancel',
};

/// Encodes a header value using the spec's base64 sentinel when it cannot be
/// carried as plain ASCII, or when it would otherwise be mistaken for one.
String _encodeHeaderValue(String value) => encodeMcpHeaderValue(value);

class StreamableHttpClientTransport implements ClientTransport {
  /// Message key (transport-internal, never sent): extra HTTP headers for
  /// this message, such as `Mcp-Param-*` (2026-07-28).
  static const String extraHeadersKey = '_headers';

  final StreamableHttpTransportConfig config;
  final http.Client _httpClient;

  final StreamController<dynamic> _messageController =
      StreamController.broadcast();
  final Completer<void> _closeCompleter = Completer<void>();

  bool _isClosed = false;
  final Semaphore _requestSemaphore;
  String? _sessionId;
  String? _protocolVersion;
  final Map<Object, Completer<dynamic>> _pendingRequests = {};
  bool _getStreamActive = false;

  /// The POST carrying `notifications/initialized`, once sent.
  Future<void>? _initializedSent;

  /// Abort triggers of requests in flight, by JSON-RPC id.
  final Map<Object, Completer<void>> _aborts = {};

  /// Close the HTTP exchange of request [id] (2026-07-28: closing the
  /// request's stream is how a client cancels it on Streamable HTTP).
  void abortRequest(Object id) {
    final abort = _aborts.remove(id);
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  /// How often a lost request stream is resumed before the request fails.
  static const int _maxResumeAttempts = 5;

  StreamableHttpClientTransport._({
    required this.config,
    required http.Client httpClient,
  }) : _httpClient = httpClient,
       _requestSemaphore = Semaphore(config.maxConcurrentRequests);

  /// Spec 2025-06-18+: record the negotiated MCP protocol version so
  /// every post-handshake HTTP request carries
  /// `MCP-Protocol-Version: <version>`.
  void setProtocolVersion(String? version) {
    _protocolVersion = version;
  }

  /// [body] when it is a JSON-RPC error response to [requestId].
  static Map<String, dynamic>? _jsonRpcErrorFor(String body, Object? requestId) {
    if (requestId == null || body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map &&
          decoded['jsonrpc'] == '2.0' &&
          decoded['error'] is Map &&
          decoded['id'] == requestId) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Create a new Streamable HTTP transport
  static Future<StreamableHttpClientTransport> create({
    required String baseUrl,
    McpOAuth? oauth,
    Map<String, String>? headers,
    RequestHeadersProvider? headersProvider,
    Duration? headersProviderTimeout,
    Duration? timeout,
    int? maxConcurrentRequests,
    bool? useHttp2,
    http.Client? httpClient,
    bool terminateOnClose = true,  // Default: true for backward compatibility
  }) async {
    final config = StreamableHttpTransportConfig(
      baseUrl: baseUrl,
      oauth: oauth,
      headers: headers ?? const {},
      headersProvider: headersProvider,
      headersProviderTimeout:
          headersProviderTimeout ?? const Duration(seconds: 5),
      timeout: timeout ?? const Duration(seconds: 30),
      maxConcurrentRequests: maxConcurrentRequests ?? 10,
      useHttp2: useHttp2 ?? true,
      terminateOnClose: terminateOnClose,
    );

    final client = httpClient ?? http.Client();

    return StreamableHttpClientTransport._(
      config: config,
      httpClient: client,
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

  /// The authorization this transport uses, if any.
  McpOAuth? get oauth => config.oauth;

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

    // Lifecycle: nothing may overtake `notifications/initialized`, and
    // separate POSTs are not ordered — so later messages wait for it.
    final Future<void> sent;
    if (message is Map && message['method'] == 'notifications/initialized') {
      sent = _initializedSent = _sendRequest(message);
    } else {
      final gate = _initializedSent;
      sent = gate == null
          ? _sendRequest(message)
          : gate.catchError((Object _) {}).then((_) => _sendRequest(message));
    }
    sent.catchError((error) {
      // A long-lived stateless `subscriptions/listen` SSE POST can still be
      // unwinding when the transport is torn down (disconnect force-closes the
      // connection). Guard against reporting the resulting connection error onto
      // an already-closed controller.
      if (!_isClosed && !_messageController.isClosed) {
        _messageController.addError(error);
      }
    });
  }

  /// Send HTTP request with proper authentication. [authorized]: a 401 /
  /// 403 has already been answered for this message (retry at most once).
  Future<void> _sendRequest(dynamic message, {bool authorized = false}) async {
    var retry = false;
    // Check if transport is closed before sending
    if (_isClosed) {
      _logger.debug('Transport closed, ignoring request');
      return;
    }

    await _requestSemaphore.acquire();

    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        // StreamableHTTP standard requires accepting both content types
        'Accept': 'application/json, text/event-stream',
        ...await _providedHeaders('POST'),
        ...config.headers,
      };

      // Add session ID if available
      if (_sessionId != null) {
        headers['MCP-Session-Id'] = _sessionId!;
      }

      // Spec 2025-06-18+: every post-handshake HTTP request MUST carry
      // the negotiated protocol version. Older revisions ignore this
      // header. Set via [setProtocolVersion] after initialize. On the
      // 2026-07-28 stateless path the header is the sole version signal, so
      // it is always attached there too.
      if (_protocolVersion != null &&
          (McpProtocol.requiresProtocolHeader(_protocolVersion!) ||
              McpProtocol.isStateless(_protocolVersion!))) {
        headers['MCP-Protocol-Version'] = _protocolVersion!;
      }

      // 2026-07-28 mirrors the method — and, for the operations that name a
      // target, that name — into headers so intermediaries can route without
      // parsing the body. Values that cannot be carried as plain ASCII use the
      // spec's base64 sentinel; a mirror that disagrees with the body is a
      // rejectable mismatch, so it is derived from the body, never assumed.
      if (_protocolVersion != null &&
          McpProtocol.isStateless(_protocolVersion!) &&
          message is Map) {
        final method = message['method'];
        if (method is String) {
          headers['Mcp-Method'] = method;
          if (_methodsRequiringName.contains(method)) {
            final params = message['params'];
            final target = params is Map ? (params['name'] ?? params['uri'] ?? params['taskId']) : null;
            if (target != null) {
              headers['Mcp-Name'] = _encodeHeaderValue('$target');
            }
          }
        }
      }

      // The token for this server, on every request; with none the server
      // answers 401 and the challenge starts the authorization.
      final token = await config.oauth?.accessToken(config.baseUrl);
      if (token != null) headers['Authorization'] = 'Bearer $token';

      if (message is Map && message.containsKey(extraHeadersKey)) {
        final extra = message[extraHeadersKey];
        message = Map<String, dynamic>.from(message)..remove(extraHeadersKey);
        if (extra is Map) {
          extra.forEach((k, v) => headers['$k'] = '$v');
        }
      }
      final body = jsonEncode(message);
      final uri = Uri.parse(config.baseUrl);

      // Store the id of a request (a response this client sends to a server
      // request carries the server's id, of any type, and is not tracked).
      Object? requestId;
      if (message is Map && message['id'] != null && message['method'] != null) {
        requestId = message['id'] as Object;
        _pendingRequests[requestId] = Completer<dynamic>();
      }

      // Build a streamed request so SSE responses can be read live.
      //
      // FastMCP routes server-initiated requests
      // (`sampling/createMessage`, `elicitation/create`) on the in-flight
      // POST's SSE response stream — not the standalone GET stream — and
      // those requests fire mid-tool-call. Buffering the body via
      // `httpClient.post(...).bodyBytes` deadlocks: the server holds the
      // SSE response open waiting for our reply to a server-initiated
      // request, but we can't see the request until the stream closes.
      // Streaming the response while it's open lets us dispatch each SSE
      // event the moment it arrives.
      final abort = requestId == null ? null : (_aborts[requestId] = Completer<void>());
      final request = http.AbortableRequest('POST', uri, abortTrigger: abort?.future)
        ..body = body;
      headers.forEach((k, v) => request.headers[k] = v);

      final response =
          await _httpClient.send(request).timeout(config.timeout);

      // Extract session ID from response headers
      final newSessionId = response.headers['mcp-session-id'];
      if (newSessionId != null && newSessionId != _sessionId) {
        _sessionId = newSessionId;
        _logger.debug('Received session ID: $_sessionId');
      }

      if (response.statusCode == 202) {
        // 202 Accepted - no immediate response expected
        _logger.debug('Received 202 Accepted');
        // Drain any stray bytes so the connection can be released.
        await response.stream.drain<void>();
        return;
      }

      if (response.statusCode == 404 && headers.containsKey('MCP-Session-Id')) {
        // The session is gone: forget it, so the client starts a new one
        // with `initialize` (Streamable HTTP, session management).
        _sessionId = null;
        _getStreamActive = false;
        if (requestId != null) {
          _messageController.add({
            'jsonrpc': '2.0',
            'id': requestId,
            'error': {'code': McpProtocol.errorSessionExpired, 'message': 'Session expired'},
          });
        }
        await response.stream.drain<void>();
        return;
      }

      if ((response.statusCode == 401 || response.statusCode == 403) &&
          config.oauth != null &&
          !authorized) {
        final challenge = response.headers['www-authenticate'];
        await response.stream.drain<void>();
        try {
          retry = await config.oauth!.handleChallenge(
              serverUrl: config.baseUrl, status: response.statusCode, wwwAuthenticate: challenge);
        } on OAuthError catch (e) {
          _logger.warning('Authorization failed: $e');
          _authenticationRequired(requestId, response.statusCode, challenge, e);
          return;
        }
        if (!retry) _authenticationRequired(requestId, response.statusCode, challenge, null);
        return;
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        // Authentication required - trigger OAuth flow.
        //
        // MCP 2025-11-25 (RFC 9728 / SEP-985 / SEP-835, A5/A6): parse the
        // server's `WWW-Authenticate` challenge so consumers receive
        // actionable, structured discovery data — the RFC 9728 PRM URL
        // (`resource_metadata=`) and the required step-up `scope=` — instead
        // of only the raw header. The full discovery chain (PRM fetch → AS
        // discovery via RFC 8414/OIDC) is driven by
        // `HttpOAuthClient.discoverFrom401`, reusing the existing token flow.
        final rawChallenge = response.headers['www-authenticate'];
        final challenge = WwwAuthenticateChallenge.parse(rawChallenge);
        _messageController.add({
          'jsonrpc': '2.0',
          'error': {
            'code': McpProtocol.errorAuthenticationRequired,
            'message': 'Authentication required',
            'data': {
              'www_authenticate': rawChallenge,
              if (challenge?.resourceMetadata != null)
                'resource_metadata': challenge!.resourceMetadata,
              if (challenge != null && challenge.scopes.isNotEmpty)
                'scope': challenge.scope,
              'resource_url': config.baseUrl,
              'status': response.statusCode,
            },
          },
          if (requestId != null) 'id': requestId,
        });
        await response.stream.drain<void>();
        return;
      }

      if (response.statusCode >= 400) {
        // Buffer the error body for the exception message.
        final errorBody = await response.stream.bytesToString();
        // A JSON-RPC error answering this request (2026-07-28 sends
        // UnsupportedProtocolVersion, HeaderMismatch … with 400) is the
        // request's response, delivered like any other.
        final rpcError = _jsonRpcErrorFor(errorBody, requestId);
        if (rpcError != null) {
          _messageController.add(rpcError);
          return;
        }
        throw McpError(
          'HTTP ${response.statusCode}: ${response.reasonPhrase}'
          '${errorBody.isEmpty ? '' : ' — $errorBody'}',
        );
      }

      // Check content type
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';

      if (contentType.startsWith('application/json')) {
        // Direct JSON response - read the entire body, decode as UTF-8.
        final responseBody = await response.stream.bytesToString();
        if (responseBody.isNotEmpty) {
          final responseMessage = jsonDecode(responseBody);
          _messageController.add(responseMessage);
        }
      } else if (contentType.startsWith('text/event-stream')) {
        // SSE response — process each event as it arrives so
        // server-initiated requests embedded in this stream don't have
        // to wait for the whole tool call to finish.
        await _handleStreamedSseResponse(response, requestId);
      } else {
        _logger.warning('Unexpected content type: $contentType');
        // Try to parse as JSON anyway - read full body
        final responseBody = await response.stream.bytesToString();
        if (responseBody.isNotEmpty) {
          try {
            final responseMessage = jsonDecode(responseBody);
            _messageController.add(responseMessage);
          } catch (e) {
            _logger.error('Failed to parse response: $e');
          }
        }
      }
    } on http.RequestAbortedException {
      // The client cancelled the request by closing its exchange.
      _logger.debug('Request aborted');
    } finally {
      if (message is Map && message['id'] != null && message['method'] != null) {
        _aborts.remove(message['id']);
      }
      _requestSemaphore.release();
      // Here, not after the try: its branches return early.
      if (retry) await _sendRequest(message, authorized: true);
    }
  }

  /// Report that [requestId] cannot proceed without (more) authorization.
  void _authenticationRequired(Object? requestId, int status, String? rawChallenge, OAuthError? error) {
    final challenge = WwwAuthenticateChallenge.parse(rawChallenge);
    _messageController.add({
      'jsonrpc': '2.0',
      if (requestId != null) 'id': requestId,
      'error': {
        'code': McpProtocol.errorAuthenticationRequired,
        'message': status == 403 ? 'Insufficient scope' : 'Authentication required',
        'data': {
          'status': status,
          'www_authenticate': rawChallenge,
          if (challenge?.resourceMetadata != null) 'resource_metadata': challenge!.resourceMetadata,
          if (challenge != null && challenge.scopes.isNotEmpty) 'scope': challenge.scope,
          'resource_url': config.baseUrl,
          if (error != null) 'oauth_error': error.toJson(),
        },
      },
    });
  }

  /// Handle a streamed SSE response from a POST request, dispatching
  /// each event as it arrives. Required for cases where the server
  /// embeds server-initiated requests (`sampling/createMessage`,
  /// `elicitation/create`) in the response stream and waits for the
  /// client's reply before producing the final tool result — buffering
  /// the body would deadlock.
  Future<void> _handleStreamedSseResponse(
    http.StreamedResponse response,
    Object? requestId,
  ) async {
    _logger.debug('Handling streamed SSE response');
    var cursor = await _readSse(response.stream, requestId);
    // A request stream that ends before its response is resumed with the
    // last event id it carried (2025-03-26 .. 2025-11-25); 2026-07-28 has no
    // resumption — the request is lost and the caller re-issues it.
    final resumable = _protocolVersion == null || !McpProtocol.isStateless(_protocolVersion!);
    var attempts = 0;
    while (!cursor.delivered && requestId != null && !_isClosed && resumable) {
      if (cursor.lastEventId == null || ++attempts > _maxResumeAttempts) break;
      await Future<void>.delayed(cursor.retry ?? const Duration(seconds: 1));
      final resumed = await _openGet(lastEventId: cursor.lastEventId);
      if (resumed == null) break;
      cursor = await _readSse(resumed.stream, requestId, from: cursor);
    }
    final aborted = requestId != null && !_aborts.containsKey(requestId);
    if (!cursor.delivered && requestId != null && !_isClosed && !aborted) {
      _messageController.add({
        'jsonrpc': '2.0',
        'id': requestId,
        'error': {
          'code': McpProtocol.errorNetwork,
          'message': 'The response stream ended before the response arrived',
        },
      });
    }
  }

  /// Read one SSE stream, delivering its messages; reports whether the
  /// response to [requestId] came, and the last event id and retry seen.
  Future<_SseCursor> _readSse(Stream<List<int>> bytes, Object? requestId, {_SseCursor? from}) async {
    var cursor = from ?? const _SseCursor();
    try {
      await for (final event in bytes
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .transform(const SseParser())) {
        cursor = cursor.copyWith(lastEventId: event.id, retry: event.retry);
        if (event.data.isEmpty) continue; // priming event
        final Object? message;
        try {
          message = jsonDecode(event.data);
        } on FormatException {
          _logger.debug('Ignoring an SSE event that is not JSON');
          continue;
        }
        if (message is Map &&
            requestId != null &&
            message['id'] == requestId &&
            message['method'] == null) {
          cursor = cursor.copyWith(delivered: true);
        }
        _messageController.add(message);
      }
    } catch (e) {
      _logger.debug('SSE stream interrupted: $e');
    }
    return cursor;
  }

  /// GET on the MCP endpoint as an event stream (optionally resuming after
  /// [lastEventId]); null when the server offers none or refuses.
  Future<http.StreamedResponse?> _openGet({String? lastEventId}) async {
    if (_isClosed || _sessionId == null) return null;
    final request = http.Request('GET', Uri.parse(config.baseUrl));
    final headers = <String, String>{
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...await _providedHeaders('GET'),
      ...config.headers,
      'MCP-Session-Id': _sessionId!,
      if (_protocolVersion != null) 'MCP-Protocol-Version': _protocolVersion!,
      if (lastEventId != null) 'Last-Event-ID': lastEventId,
    };
    final token = await config.oauth?.accessToken(config.baseUrl);
    if (token != null) headers['Authorization'] = 'Bearer $token';
    headers.forEach((k, v) => request.headers[k] = v);
    final response = await _httpClient.send(request);
    if (response.statusCode == 200) return response;
    await response.stream.drain<void>();
    if (response.statusCode == 404) {
      _sessionId = null;
      _getStreamActive = false;
    }
    return null;
  }

  /// Start GET stream for server-initiated messages
  void _startGetStream() {
    if (_getStreamActive || _sessionId == null) return;
    _getStreamActive = true;
    unawaited(_runGetStream().catchError((Object error) {
      _logger.debug('GET stream ended: $error');
      _getStreamActive = false;
    }));
  }

  /// The session's GET stream: reconnected after the server closes it,
  /// resuming from the last event id (waiting the `retry` it asked for).
  /// Ends when the server offers no GET stream (405), the session ends, or
  /// the transport closes.
  Future<void> _runGetStream() async {
    var cursor = const _SseCursor();
    var failures = 0;
    while (!_isClosed && _getStreamActive && _sessionId != null) {
      final response = await _openGet(lastEventId: cursor.lastEventId);
      if (response == null) break;
      failures = 0;
      cursor = await _readSse(response.stream, null, from: cursor);
      if (_isClosed) break;
      await Future<void>.delayed(cursor.retry ?? Duration(seconds: 1 << min(++failures, 5)));
    }
    _getStreamActive = false;
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

    // The GET stream loop stops on its own once the client is closed.
    _getStreamActive = false;

    // Clear pending requests without completing them with error
    // to avoid unhandled exceptions during shutdown
    _pendingRequests.clear();

    _messageController.close();
    _httpClient.close();

    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }


  /// Headers a provider contributed for this request, minus the ones the
  /// protocol owns.
  ///
  /// Never throws and never hangs. A provider is host-supplied code — often a
  /// page script reaching for a token — and a request must not be lost to it.
  Future<Map<String, String>> _providedHeaders(String method) async {
    final provider = config.headersProvider;
    if (provider == null) return const <String, String>{};
    try {
      final supplied = await Future<Map<String, String>>.value(
        provider((url: config.baseUrl, method: method)),
      ).timeout(config.headersProviderTimeout);
      final allowed = <String, String>{};
      for (final entry in supplied.entries) {
        if (reservedHeaderNames.contains(entry.key.toLowerCase())) {
          // Silently honouring it would break the exchange in a way that
          // looks like the server's fault, so say which name was dropped.
          _logger.debug(
              'headers provider tried to set reserved header "${entry.key}"; '
              'ignored');
          continue;
        }
        allowed[entry.key] = entry.value;
      }
      return allowed;
    } catch (e) {
      // Reported, not fatal. The origin's answer to a request missing its
      // credential is the accurate thing to show, and it comes from the origin.
      _logger.debug('headers provider failed ($e); sending without it');
      lastHeadersProviderError = e;
      return const <String, String>{};
    }
  }

  /// The last failure from [StreamableHttpTransportConfig.headersProvider].
  ///
  /// Exposed so a host can tell "the origin refused us" from "we never
  /// attached what the origin wanted" — those look identical on the wire and
  /// send whoever is debugging to different places.
  Object? lastHeadersProviderError;

  /// Terminate the session
  Future<void> _terminateSession() async {
    if (_sessionId == null) return;

    try {
      final headers = <String, String>{
        'MCP-Session-Id': _sessionId!,
        ...await _providedHeaders('DELETE'),
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

/// Where an SSE stream got to.
class _SseCursor {
  const _SseCursor({this.lastEventId, this.retry, this.delivered = false});
  final String? lastEventId;
  final Duration? retry;
  final bool delivered;

  _SseCursor copyWith({String? lastEventId, Duration? retry, bool? delivered}) => _SseCursor(
        lastEventId: lastEventId ?? this.lastEventId,
        retry: retry ?? this.retry,
        delivered: delivered ?? this.delivered,
      );
}
