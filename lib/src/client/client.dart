import 'dart:async';
import 'dart:convert';

import '../../logger.dart';
import '../models/models.dart';
import '../models/elicitation.dart';
import '../protocol/protocol.dart';
import '../protocol/request_meta.dart';
import '../protocol/multi_round_trip.dart';
import '../protocol/tasks.dart';
import '../transport/streamable_http_transport.dart';
import '../transport/transport.dart';

final Logger _logger = Logger('mcp_client.client');

/// Main MCP Client class that handles all client-side protocol operations
class Client {
  /// Name of the MCP client
  final String name;

  /// Version of the MCP client implementation
  final String version;

  /// Spec 2025-11-25+: optional human-readable description of this client
  /// implementation. Emitted on `clientInfo` during initialize when set;
  /// older peers ignore it (additive).
  final String? description;

  /// Client capabilities configuration
  final ClientCapabilities capabilities;

  /// Protocol version this client implements
  final String protocolVersion = McpProtocol.defaultVersion;

  /// Transport connection
  ClientTransport? _transport;

  /// Stream controller for handling incoming messages
  final _messageController = StreamController<JsonRpcMessage>.broadcast();

  /// Stream controller for connection events
  final _connectStreamController = StreamController<ServerInfo>.broadcast();

  /// Stream controller for disconnection events
  final _disconnectStreamController =
      StreamController<DisconnectReason>.broadcast();

  /// Stream controller for error events
  final _errorStreamController = StreamController<McpError>.broadcast();

  /// Request identifier counter
  int _requestId = 1;

  /// Map of request completion handlers by ID
  final _requestCompleters = <int, Completer<dynamic>>{};

  /// Map of notification handlers by method
  final _notificationHandlers = <String, Function(Map<String, dynamic>)>{};

  /// Map of incoming-request handlers by method (server-initiated requests
  /// per spec: `sampling/createMessage`, `roots/list`, `elicitation/create`).
  /// Each handler returns the JSON-RPC `result` map.
  final _requestHandlers =
      <String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>{};

  /// Live 2026-07-28 `subscriptions/listen` streams (SEP-2577), keyed by the
  /// subscriptionId (the listen request's JSON-RPC id). Populated only on the
  /// stateless path via [listen].
  final _subscriptions = <int, _ClientSubscription>{};

  /// Local roots advertised by this client. The server can fetch the
  /// list via the `roots/list` request — handled by the built-in
  /// incoming-request handler. Mutations push
  /// `notifications/roots/list_changed` to the server.
  final List<Root> _roots = <Root>[];

  /// Server capabilities received during initialization
  ServerCapabilities? _serverCapabilities;

  /// Server information received during initialization
  Map<String, dynamic>? _serverInfo;

  /// Whether the client is currently connected
  bool get isConnected => _transport != null;

  /// Whether initialization is complete
  bool _initialized = false;

  /// Whether the client is currently connecting
  bool _connecting = false;

  /// 2026-07-28 stateless-core mode (SEP-2577). Off by default (dormant). When
  /// on, [connect] skips the `initialize` handshake, every request carries the
  /// reverse-DNS `_meta` keys (protocol version + per-request client caps +
  /// clientInfo) and the `MCP-Protocol-Version: 2026-07-28` header, and the
  /// strict server==client version equality check is dropped.
  bool _statelessMode = false;

  /// Whether this client is operating in the 2026-07-28 stateless mode.
  bool get isStateless => _statelessMode;

  /// Get the server capabilities
  ServerCapabilities? get serverCapabilities => _serverCapabilities;

  /// Get the server information
  Map<String, dynamic>? get serverInfo => _serverInfo;

  /// Stream of connection events
  Stream<ServerInfo> get onConnect => _connectStreamController.stream;

  /// Stream of disconnection events
  Stream<DisconnectReason> get onDisconnect =>
      _disconnectStreamController.stream;

  /// Stream of error events
  Stream<McpError> get onError => _errorStreamController.stream;

  /// Creates a new MCP client with the specified parameters
  Client({
    required this.name,
    required this.version,
    this.description,
    this.capabilities = const ClientCapabilities(),
  }) {
    // Default `roots/list` handler returns the locally registered roots.
    // Hosts may override with [onListRoots] for dynamic roots.
    _requestHandlers['roots/list'] = (_) async => {
          'roots': _roots.map((r) => r.toJson()).toList(),
        };
  }

  /// Connect the client to a transport.
  ///
  /// When [statelessMode] is true, the client speaks the 2026-07-28 stateless
  /// core: it skips the `initialize` handshake, marks the transport to stamp
  /// `MCP-Protocol-Version: 2026-07-28` on every request, and attaches the
  /// reverse-DNS `_meta` keys (client info + per-request capabilities) to each
  /// outbound request. Server capabilities are fetched on demand via
  /// [discover]. Default false (dormant) — the handshake path is unchanged.
  Future<void> connect(
    ClientTransport transport, {
    bool statelessMode = false,
  }) async {
    if (_transport != null) {
      throw McpError('Client is already connected to a transport');
    }

    if (_connecting) {
      throw McpError('Client is already connecting to a transport');
    }

    _connecting = true;
    _statelessMode = statelessMode;
    _transport = transport;
    _transport!.onMessage.listen(_handleMessage);
    _transport!.onClose
        .then((_) {
          // Only send disconnect event if we're still connected
          if (_transport != null) {
            _disconnectStreamController.add(DisconnectReason.transportClosed);
            _onDisconnect();
          }
        })
        .catchError((error) {
          // Only handle error if we're still connected
          if (_transport != null) {
            _errorStreamController.add(McpError('Transport error: $error'));
            _disconnectStreamController.add(DisconnectReason.transportError);
            _onDisconnect();
          }
        });

    // Set up message handling
    _messageController.stream.listen((message) async {
      try {
        await _processMessage(message);
      } catch (e) {
        _logger.debug('Error processing message: $e');
        _errorStreamController.add(McpError('Error processing message: $e'));
      }
    });

    // Initialize the connection
    try {
      if (_statelessMode) {
        // Stateless core: no handshake. Record the version so the HTTP
        // transport stamps `MCP-Protocol-Version: 2026-07-28`, and mark the
        // client ready to send requests immediately. Server capabilities are
        // fetched on demand via [discover].
        _negotiatedProtocolVersion = McpProtocol.v2026_07_28;
        final tx = _transport;
        if (tx is StreamableHttpClientTransport) {
          tx.setProtocolVersion(McpProtocol.v2026_07_28);
        }
        _initialized = true;
      } else {
        await initialize();
      }
      _connecting = false;

      // Emit connection event after successful initialization
      if (_initialized && _serverInfo != null && _serverCapabilities != null) {
        _connectStreamController.add(
          ServerInfo(
            name: _serverInfo!['name'] as String? ?? 'Unknown',
            version: _serverInfo!['version'] as String? ?? 'Unknown',
            capabilities: _serverCapabilities!.toJson(),
            protocolVersion: protocolVersion,
          ),
        );
      }
    } catch (e) {
      _connecting = false;
      _errorStreamController.add(McpError('Initialization error: $e'));
      disconnect();
      rethrow;
    }
  }

  /// Connect with retry mechanism
  Future<void> connectWithRetry(
    ClientTransport transport, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 2),
  }) async {
    if (_transport != null) {
      throw McpError('Client is already connected to a transport');
    }

    if (_connecting) {
      throw McpError('Client is already connecting to a transport');
    }

    _connecting = true;
    int attempts = 0;

    while (attempts < maxRetries) {
      try {
        _transport = transport;
        _transport!.onMessage.listen(_handleMessage);
        _transport!.onClose
            .then((_) {
              // Only send disconnect event if we're still connected
              if (_transport != null) {
                _disconnectStreamController.add(
                  DisconnectReason.transportClosed,
                );
                _onDisconnect();
              }
            })
            .catchError((error) {
              // Only handle error if we're still connected
              if (_transport != null) {
                _errorStreamController.add(McpError('Transport error: $error'));
                _disconnectStreamController.add(
                  DisconnectReason.transportError,
                );
                _onDisconnect();
              }
            });

        // Message handling setup
        _messageController.stream.listen((message) async {
          try {
            await _processMessage(message);
          } catch (e) {
            _logger.debug('Error processing message: $e');
            _errorStreamController.add(
              McpError('Error processing message: $e'),
            );
          }
        });

        // Initialize connection
        await initialize();
        _connecting = false;

        // Emit connection event after successful initialization
        if (_initialized &&
            _serverInfo != null &&
            _serverCapabilities != null) {
          _connectStreamController.add(
            ServerInfo(
              name: _serverInfo!['name'] as String? ?? 'Unknown',
              version: _serverInfo!['version'] as String? ?? 'Unknown',
              capabilities: _serverCapabilities!.toJson(),
              protocolVersion: protocolVersion,
            ),
          );
        }

        return; // Successfully connected
      } catch (e) {
        // Clean up resources on failure
        if (_transport != null) {
          try {
            _transport!.close();
          } catch (_) {}
          _transport = null;
        }

        attempts++;
        if (attempts >= maxRetries) {
          _connecting = false;
          _errorStreamController.add(
            McpError('Failed to connect after $maxRetries attempts: $e'),
          );
          throw McpError('Failed to connect after $maxRetries attempts: $e');
        }

        _logger.debug(
          'Connection attempt $attempts failed: $e. Retrying in ${delay.inSeconds} seconds...',
        );
        await Future.delayed(delay);
      }
    }
  }

  /// Initialize the connection to the server
  Future<void> initialize() async {
    if (_initialized) {
      throw McpError('Client is already initialized');
    }

    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final response = await _sendRequest('initialize', {
      'protocolVersion': protocolVersion,
      // Spec 2025-11-25+ allows `Implementation.description` on clientInfo;
      // emitted only when set, so older peers see the pre-2025-11-25 shape.
      'clientInfo': {
        'name': name,
        'version': version,
        if (description != null) 'description': description,
      },
      'capabilities': capabilities.toJson(),
    });

    if (response == null) {
      throw McpError('Failed to initialize: No response from server');
    }

    final serverProtoVersion = response['protocolVersion'];
    if (serverProtoVersion != protocolVersion) {
      _validateProtocolVersion(serverProtoVersion);
    }

    _serverInfo = response['serverInfo'];
    final capabilitiesData = response['capabilities'];
    _serverCapabilities = ServerCapabilities.fromJson(
      capabilitiesData != null
          ? Map<String, dynamic>.from(capabilitiesData as Map)
          : {},
    );

    // Capture the negotiated revision and inform the transport so HTTP
    // implementations can stamp `MCP-Protocol-Version: <version>` on
    // every post-handshake request (spec 2025-06-18+).
    if (serverProtoVersion is String) {
      _negotiatedProtocolVersion = serverProtoVersion;
      // HTTP transports attach `MCP-Protocol-Version` to subsequent
      // requests when the negotiated revision is 2025-06-18+. Other
      // transports (stdio / SSE) ignore the header so we only forward
      // when the concrete transport exposes the setter.
      final tx = _transport;
      if (tx is StreamableHttpClientTransport) {
        tx.setProtocolVersion(serverProtoVersion);
      }
    }

    // Send initialized notification
    _sendNotification('notifications/initialized', {});

    _initialized = true;
    _logger.debug('Initialization complete');
  }

  /// Negotiated protocol revision after initialize completes; null
  /// before then.
  String? get negotiatedProtocolVersion => _negotiatedProtocolVersion;
  String? _negotiatedProtocolVersion;

  /// 2026-07-28 stateless core: fetch the server's supported versions,
  /// capabilities, and optional instructions via `server/discover`.
  ///
  /// Servers MUST implement `server/discover`; clients MAY call it (version
  /// negotiation can also happen inline via per-request `_meta`). Callable
  /// without a prior handshake. As a side effect the parsed
  /// [ServerCapabilities] and server info are cached on this client
  /// ([serverCapabilities] / [serverInfo]).
  Future<DiscoverResult> discover() async {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }
    final response = await _sendRequest('server/discover', {});
    if (response == null) {
      throw McpError('server/discover returned no result');
    }
    final map = Map<String, dynamic>.from(response as Map);

    final versions = (map['supportedVersions'] as List?)
            ?.map((v) => v.toString())
            .toList() ??
        const <String>[];
    final capsData = map['capabilities'];
    final caps = ServerCapabilities.fromJson(
      capsData is Map ? Map<String, dynamic>.from(capsData) : {},
    );
    _serverCapabilities = caps;

    // ResultMetaObject may carry `serverInfo` (2026-07-28).
    final serverInfo = McpRequestMeta.readServerInfo(map['_meta']);
    if (serverInfo != null) {
      _serverInfo = serverInfo;
    }

    return DiscoverResult(
      supportedVersions: versions,
      capabilities: caps,
      instructions: map['instructions'] as String?,
      ttlMs: (map['ttlMs'] as num?)?.toInt(),
      cacheScope: map['cacheScope'] as String?,
      serverInfo: serverInfo,
    );
  }

  // ── Tasks extension (io.modelcontextprotocol/tasks, 2026-07-28) ──────────

  /// Whether the server advertised the tasks extension (from the last
  /// `initialize`/`discover`). Task calls only make sense when true.
  bool get supportsTasks =>
      _serverCapabilities?.hasExtension(tasksExtensionId) ?? false;

  /// If a `tools/call` (or other) result is a `CreateTaskResult`
  /// (`resultType: "task"`), returns the [Task] handle; otherwise null.
  Task? taskFromResult(Map<String, dynamic> result) =>
      McpResultType.of(result) == McpResultType.task
          ? Task.fromJson(result)
          : null;

  /// Poll a task's current state (`tasks/get`).
  Future<Task> getTask(String taskId) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    final response = await _sendRequest('tasks/get', {'taskId': taskId});
    if (response == null) throw McpError('tasks/get returned no result');
    return Task.fromJson(Map<String, dynamic>.from(response as Map));
  }

  /// Deliver input responses to an `input_required` task (`tasks/update`).
  /// [inputResponses] is keyed by the task's outstanding `inputRequests` keys.
  Future<void> updateTask(
      String taskId, Map<String, dynamic> inputResponses) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    await _sendRequest(
        'tasks/update', {'taskId': taskId, 'inputResponses': inputResponses});
  }

  /// Cancel a task (`tasks/cancel`, cooperative + eventually consistent).
  Future<void> cancelTask(String taskId) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    await _sendRequest('tasks/cancel', {'taskId': taskId});
  }

  /// Validate protocol version compatibility
  void _validateProtocolVersion(String serverProtoVersion) {
    _logger.warning(
      'Protocol version mismatch: Client=$protocolVersion, Server=$serverProtoVersion',
    );

    // Check if server protocol version is at least compatible
    try {
      final clientDate = DateTime.parse(protocolVersion);
      final serverDate = DateTime.parse(serverProtoVersion);

      if (serverDate.isBefore(clientDate)) {
        _logger.warning(
          'Server protocol version ($serverProtoVersion) is older than client protocol version ($protocolVersion)',
        );
      }
    } catch (e) {
      // Date parsing failed, fallback to string comparison
      _logger.warning(
        'Unable to parse protocol versions as dates for comparison',
      );
    }
  }

  /// List available tools on the server
  Future<List<Tool>> listTools() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    final response = await _sendRequest('tools/list', {});
    final toolsList = response['tools'] as List<dynamic>;
    return toolsList.map((tool) => Tool.fromJson(tool)).toList();
  }

  /// Call a tool on the server
  Future<CallToolResult> callTool(
    String name,
    Map<String, dynamic> toolArguments,
  ) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    // Create a clean params map with properly typed values
    final Map<String, dynamic> params = {
      'name': name,
      'arguments': Map<String, dynamic>.from(toolArguments),
    };

    // 2026-07-28 (SEP-2577): a stateless `tools/call` may return
    // `input_required`; the MRTR driver fulfills the server's input requests and
    // re-issues until a terminal result. Legacy path = a single request.
    final response = _statelessMode
        ? await _sendRequestWithMrtr('tools/call', params)
        : await _sendRequest('tools/call', params);
    return CallToolResult.fromJson(response);
  }

  /// Call a tool and get the operation ID for tracking progress
  ///
  /// [name] - The name of the tool to call
  /// [arguments] - The arguments to pass to the tool
  /// [trackProgress] - Whether to track progress for this tool call
  ///
  /// Returns a Future that resolves to a tuple of (operationId, result)
  Future<ToolCallTracking> callToolWithTracking(
    String name,
    Map<String, dynamic> arguments, {
    bool trackProgress = true,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    final params = {
      'name': name,
      'arguments': Map<String, dynamic>.from(arguments),
      'trackProgress': trackProgress,
    };

    final response = await _sendRequest('tools/call', params);
    final operationId = response['operationId'] as String?;
    final result = CallToolResult.fromJson(response);

    return ToolCallTracking(operationId: operationId, result: result);
  }

  /// Cancel an in-flight server-side operation.
  ///
  /// Per spec, cancellation is a NOTIFICATION (`notifications/cancelled`),
  /// not a request — fire-and-forget with `requestId` and an optional
  /// `reason`.
  void notifyCancelled(String requestId, {String? reason}) {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    _sendNotification('notifications/cancelled', {
      'requestId': requestId,
      if (reason != null) 'reason': reason,
    });
  }

  /// Report progress on an in-flight server-initiated request (spec
  /// `notifications/progress`). [progressToken] is the token the server
  /// sent in the original request's `_meta.progressToken`.
  void notifyProgress(
    dynamic progressToken,
    double progress, {
    double? total,
    String? message,
  }) {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    _sendNotification('notifications/progress', {
      'progressToken': progressToken,
      'progress': progress,
      if (total != null) 'total': total,
      if (message != null) 'message': message,
    });
  }

  /// List available resources on the server
  Future<List<Resource>> listResources() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest('resources/list', {});
    final resourcesList = response['resources'] as List<dynamic>;
    return resourcesList
        .map((resource) => Resource.fromJson(resource))
        .toList();
  }

  /// Read a resource from the server
  Future<ReadResourceResult> readResource(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = _statelessMode
        ? await _sendRequestWithMrtr('resources/read', {'uri': uri})
        : await _sendRequest('resources/read', {'uri': uri});

    return ReadResourceResult.fromJson(response);
  }

  /// Get a resource using a template
  ///
  /// [templateUri] - The URI template to use
  /// [params] - Parameters to fill in the template
  ///
  /// Returns a Future that resolves to the resource content
  Future<ReadResourceResult> getResourceWithTemplate(
    String templateUri,
    Map<String, dynamic> params,
  ) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    // Construct a URI from the template and parameters
    // This is a simple implementation - for complex URI templates,
    // a more robust implementation would be needed
    String uri = templateUri;
    params.forEach((key, value) {
      uri = uri.replaceAll('{$key}', Uri.encodeComponent(value.toString()));
    });

    return await readResource(uri);
  }

  /// Subscribe to a resource
  Future<void> subscribeResource(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    await _sendRequest('resources/subscribe', {'uri': uri});
  }

  /// Unsubscribe from a resource
  Future<void> unsubscribeResource(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    await _sendRequest('resources/unsubscribe', {'uri': uri});
  }

  /// List resource templates on the server
  Future<List<ResourceTemplate>> listResourceTemplates() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest('resources/templates/list', {});
    final templatesList = response['resourceTemplates'] as List<dynamic>;
    return templatesList
        .map((template) => ResourceTemplate.fromJson(template))
        .toList();
  }

  /// List available prompts on the server
  Future<List<Prompt>> listPrompts() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.prompts != true) {
      throw McpError('Server does not support prompts');
    }

    final response = await _sendRequest('prompts/list', {});
    final promptsList = response['prompts'] as List<dynamic>;
    return promptsList.map((prompt) => Prompt.fromJson(prompt)).toList();
  }

  /// Get a prompt from the server
  Future<GetPromptResult> getPrompt(
    String name, [
    Map<String, dynamic>? promptArguments,
  ]) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.prompts != true) {
      throw McpError('Server does not support prompts');
    }

    // Create a new map to hold params to avoid direct modification
    final Map<String, dynamic> params = {'name': name};

    // Only add arguments if provided, and ensure it's a proper Map<String, dynamic>
    if (promptArguments != null) {
      params['arguments'] = Map<String, dynamic>.from(promptArguments);
    }

    final response = _statelessMode
        ? await _sendRequestWithMrtr('prompts/get', params)
        : await _sendRequest('prompts/get', params);
    return GetPromptResult.fromJson(response);
  }

  /// Register a handler for server-initiated `sampling/createMessage`
  /// requests. The driver app (Claude Desktop / Claude Code / a vibe-style
  /// IDE) fulfils the prompt with its own LLM and returns the spec
  /// `CreateMessageResult` (`role`, `content`, `model`, optional
  /// `stopReason`).
  ///
  /// Calling this advertises the `sampling` client capability during the
  /// next initialize handshake.
  void onSamplingRequest(
    Future<CreateMessageResult> Function(CreateMessageRequest request) handler,
  ) {
    _requestHandlers['sampling/createMessage'] = (params) async {
      final req = CreateMessageRequest.fromJson(params);
      final result = await handler(req);
      return result.toJson();
    };
  }

  /// Map-based variant of [onSamplingRequest]. Receives the spec
  /// `CreateMessageRequest.params` as a raw map and must return the
  /// raw `CreateMessageResult` map.
  ///
  /// Exists so generic adapters (notably `mcp_llm`'s `LlmClientAdapter`)
  /// can register a handler without importing the typed
  /// [CreateMessageRequest] / [CreateMessageResult] models — the typed
  /// entry point's signature would otherwise fail the runtime function
  /// subtype check at dynamic dispatch time.
  void onSamplingRequestMap(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) {
    _requestHandlers['sampling/createMessage'] = handler;
  }

  /// Register a handler for server-initiated `elicitation/create`
  /// requests (spec 2025-06-18). The handler shows the requested form to
  /// the user and returns `{ action, content? }` per spec — `action` is
  /// `accept` / `decline` / `cancel`.
  ///
  /// Calling this advertises the `elicitation` client capability.
  void onElicitationRequest(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) {
    _requestHandlers['elicitation/create'] = handler;
  }

  /// Typed variant of [onElicitationRequest] (spec 2025-11-25). The handler
  /// receives a parsed [ElicitationRequest] — form fields typed as
  /// [ElicitationFieldSchema] (strings/numbers/booleans with defaults,
  /// single- and multi-select enums with `enumNames`), or a URL-mode request
  /// (`mode: "url"`) — and returns a typed [ElicitationResponse].
  ///
  /// This is a convenience over the raw-map path; the wire behavior is
  /// identical. Registering either handler overrides the other (both bind
  /// the same `elicitation/create` slot). Calling this advertises the
  /// `elicitation` client capability.
  void onElicitationRequestTyped(
    Future<ElicitationResponse> Function(ElicitationRequest request) handler,
  ) {
    _requestHandlers['elicitation/create'] = (params) async {
      final req = ElicitationRequest.fromJson(params);
      final res = await handler(req);
      return res.toJson();
    };
  }

  /// Register a custom handler for server-initiated `roots/list` requests.
  /// By default the client responds with the locally configured [roots]
  /// list — supply this to override.
  void onListRoots(
    Future<List<Root>> Function() handler,
  ) {
    _requestHandlers['roots/list'] = (params) async {
      final list = await handler();
      return {
        'roots': list.map((r) => r.toJson()).toList(),
      };
    };
  }

  /// Map-based variant of [onListRoots]. The handler returns the raw
  /// list of root maps (each with at least a `uri` key); this method
  /// wraps it in the spec response shape. Sibling to
  /// [onSamplingRequestMap] — same rationale.
  void onListRootsMap(
    Future<List<Map<String, dynamic>>> Function() handler,
  ) {
    _requestHandlers['roots/list'] = (params) async {
      final list = await handler();
      return {'roots': list};
    };
  }

  /// Locally configured roots (URI / filesystem boundaries the server is
  /// allowed to operate in). Mutations push
  /// `notifications/roots/list_changed` to the server.
  List<Root> get roots => List.unmodifiable(_roots);

  /// Add a root to the client's local list. Server is notified via
  /// `notifications/roots/list_changed`.
  void addRoot(Root root) {
    if (_roots.any((r) => r.uri == root.uri)) {
      throw McpError('Root with URI "${root.uri}" already exists');
    }
    _roots.add(root);
    if (isConnected) {
      _sendNotification('notifications/roots/list_changed', {});
    }
  }

  /// Map-based variant of [addRoot] for callers that don't have the
  /// typed [Root] available. Constructs a [Root] from the supplied map
  /// (must contain at least `uri`) and delegates to [addRoot].
  void addRootMap(Map<String, dynamic> root) {
    addRoot(Root.fromJson(root));
  }

  /// Remove a root from the client's local list. Server is notified via
  /// `notifications/roots/list_changed`.
  void removeRoot(String uri) {
    final removed = _roots.length;
    _roots.removeWhere((r) => r.uri == uri);
    if (_roots.length == removed) {
      throw McpError('Root with URI "$uri" does not exist');
    }
    if (isConnected) {
      _sendNotification('notifications/roots/list_changed', {});
    }
  }

  /// Set the logging level for the server
  Future<void> setLoggingLevel(McpLogLevel level) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    // Spec method name is camelCase: `logging/setLevel`.
    await _sendRequest('logging/setLevel', {'level': level.name});
  }

  /// Register a notification handler
  void onNotification(String method, Function(Map<String, dynamic>) handler) {
    _notificationHandlers[method] = handler;
  }

  /// Handle tools list changed notification
  void onToolsListChanged(Function() handler) {
    onNotification(McpProtocol.methodToolListChanged, (_) => handler());
  }

  /// Handle resources list changed notification
  void onResourcesListChanged(Function() handler) {
    onNotification(McpProtocol.methodResourceListChanged, (_) => handler());
  }

  /// Handle prompts list changed notification
  void onPromptsListChanged(Function() handler) {
    onNotification(McpProtocol.methodPromptListChanged, (_) => handler());
  }

  /// Handle roots list changed notification
  void onRootsListChanged(Function() handler) {
    onNotification('notifications/roots/list_changed', (_) => handler());
  }

  /// Handle resource updated notification
  void onResourceUpdated(Function(String) handler) {
    onNotification(McpProtocol.methodResourceUpdated, (params) {
      final uri = params['uri'] as String;
      handler(uri);
    });
  }

  /// Register a handler for resource update notifications with content
  ///
  /// The handler will be called with:
  /// [uri] - The URI of the updated resource
  /// [content] - The new content of the resource
  void onResourceContentUpdated(
    Function(String uri, ResourceContentInfo content) handler,
  ) {
    onNotification(McpProtocol.methodResourceUpdated, (params) {
      final uri = params['uri'] as String;
      final contentData = params['content'] as Map<String, dynamic>;
      final content = ResourceContentInfo.fromJson(contentData);
      handler(uri, content);
    });
  }

  /// Register a handler for progress updates from the server
  ///
  /// The handler will be called with:
  /// [requestId] - The ID of the request that this progress update relates to
  /// [progress] - A value between 0.0 and 1.0 indicating the progress
  /// [message] - Optional message describing the current progress state
  void onProgress(
    Function(String requestId, double progress, String message) handler,
  ) {
    onNotification(McpProtocol.methodProgress, (params) {
      final requestId =
          params['requestId'] as String? ?? params['request_id'] as String;
      final progress = params['progress'] as double;
      final message = params['message'] as String;
      handler(requestId, progress, message);
    });
  }

  // `onSamplingResponse` (non-spec `sampling/response` notification) was
  // removed in 2.0. Sampling now follows the spec request/response shape:
  // server sends `sampling/createMessage` request → client's
  // [onSamplingRequest] handler returns the result.

  /// Handle logging notification
  void onLogging(
    Function(McpLogLevel, String, String?, Map<String, dynamic>?) handler,
  ) {
    onNotification(McpProtocol.methodLog, (params) {
      // Parse level as string according to MCP 2025-03-26 spec
      final levelString = params['level'] as String;
      final level = _parseLogLevel(levelString);

      final logger = params['logger'] as String?;

      // Extract message and additional data from data object according to spec
      final dataMap = params['data'] as Map<String, dynamic>?;
      final message = dataMap?['message'] as String? ?? '';

      handler(level, message, logger, dataMap);
    });
  }

  /// Parse log level string to enum value
  McpLogLevel _parseLogLevel(String levelString) {
    switch (levelString.toLowerCase()) {
      case 'debug':
        return McpLogLevel.debug;
      case 'info':
        return McpLogLevel.info;
      case 'notice':
        return McpLogLevel.notice;
      case 'warning':
        return McpLogLevel.warning;
      case 'error':
        return McpLogLevel.error;
      case 'critical':
        return McpLogLevel.critical;
      case 'alert':
        return McpLogLevel.alert;
      case 'emergency':
        return McpLogLevel.emergency;
      default:
        return McpLogLevel.info; // fallback to info level
    }
  }

  /// Disconnect the client from its transport
  void disconnect() {
    if (_transport != null) {
      _disconnectStreamController.add(DisconnectReason.clientDisconnected);
      final transport = _transport;
      _transport =
          null; // Clear reference before closing to avoid double events
      transport!.close();
      _onDisconnect();
    }
  }

  /// Dispose client resources
  void dispose() {
    disconnect();

    // Close all stream controllers
    _messageController.close();
    _connectStreamController.close();
    _disconnectStreamController.close();
    _errorStreamController.close();
  }

  /// Handle transport disconnection
  void _onDisconnect() {
    _transport = null;
    _initialized = false;

    // Complete any pending requests with an error
    for (final completer in _requestCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(McpError('Transport disconnected'));
      }
    }
    _requestCompleters.clear();
  }

  /// Handle incoming messages from the transport
  void _handleMessage(dynamic rawMessage) {
    try {
      final message = JsonRpcMessage.fromJson(
        rawMessage is String ? jsonDecode(rawMessage) : rawMessage,
      );
      _messageController.add(message);
    } catch (e) {
      _logger.debug('Error parsing message: $e');
      _errorStreamController.add(McpError('Error parsing message: $e'));
    }
  }

  /// Process a JSON-RPC message
  Future<void> _processMessage(JsonRpcMessage message) async {
    if (message.isResponse) {
      _handleResponse(message);
    } else if (message.isNotification) {
      _handleNotification(message);
    } else if (message.isRequest) {
      // Server-initiated request — sampling / elicitation / roots / etc.
      await _handleIncomingRequest(message);
    } else {
      _logger.debug('Ignoring unexpected message type: ${message.toJson()}');
    }
  }

  /// Dispatch an incoming server-initiated request to a registered handler
  /// and send the JSON-RPC response back. Spec methods routed here:
  ///   - `sampling/createMessage` (driver app's LLM)
  ///   - `roots/list` (client's filesystem / URI roots)
  ///   - `elicitation/create` (user input prompt)
  Future<void> _handleIncomingRequest(JsonRpcMessage request) async {
    final method = request.method;
    final id = request.id;
    if (method == null || id == null) {
      return;
    }
    final handler = _requestHandlers[method];
    if (handler == null) {
      _sendErrorResult(
        id,
        code: McpProtocol.errorMethodNotFound,
        message: 'Method not found: $method',
      );
      return;
    }
    try {
      final result = await handler(request.params ?? const {});
      _sendResultResponse(id, result);
    } catch (e) {
      _sendErrorResult(
        id,
        code: -32603, // internal error
        message: 'Handler error: $e',
      );
    }
  }

  /// Send a JSON-RPC `result` response to the server.
  void _sendResultResponse(dynamic id, Map<String, dynamic> result) {
    final transport = _transport;
    if (transport == null) return;
    transport.send({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  /// Send a JSON-RPC `error` response to the server.
  void _sendErrorResult(dynamic id,
      {required int code, required String message, dynamic data}) {
    final transport = _transport;
    if (transport == null) return;
    transport.send({
      'jsonrpc': '2.0',
      'id': id,
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });
  }

  /// Handle a JSON-RPC response
  void _handleResponse(JsonRpcMessage response) {
    final id = response.id;
    // 2026-07-28 (SEP-2577): the terminal `SubscriptionsListenResult` (id ==
    // subscriptionId) closes the subscription stream gracefully.
    if (id is int && _subscriptions.containsKey(id)) {
      final sub = _subscriptions.remove(id)!;
      if (!sub.ackCompleter.isCompleted) {
        sub.ackCompleter.complete(const SubscriptionFilter());
      }
      if (!sub.controller.isClosed) sub.controller.close();
      return;
    }
    if (id == null || id is! int || !_requestCompleters.containsKey(id)) {
      _logger.debug('Received response with unknown id: $id');
      return;
    }

    final completer = _requestCompleters.remove(id)!;

    if (response.error != null) {
      final code = response.error!['code'] as int;
      final message = response.error!['message'] as String;
      final error = McpError(message, code: code);
      _errorStreamController.add(error);
      completer.completeError(error);
    } else {
      completer.complete(response.result);
    }
  }

  /// Handle a JSON-RPC notification
  void _handleNotification(JsonRpcMessage notification) {
    final method = notification.method;
    final params = notification.params ?? {};

    // 2026-07-28 (SEP-2577): a notification stamped with `_meta.subscriptionId`
    // belongs to a `subscriptions/listen` stream. The first such message is the
    // `acknowledged` notification (resolves the honored filter); the rest are
    // stream notifications fed to the subscription's stream.
    final subId = McpRequestMeta.readSubscriptionId(params['_meta']);
    if (subId is int && _subscriptions.containsKey(subId)) {
      final sub = _subscriptions[subId]!;
      if (method == 'notifications/subscriptions/acknowledged') {
        if (!sub.ackCompleter.isCompleted) {
          final n = params['notifications'];
          sub.ackCompleter.complete(n is Map
              ? SubscriptionFilter.fromJson(Map<String, dynamic>.from(n))
              : const SubscriptionFilter());
        }
        return;
      }
      if (method != null && !sub.controller.isClosed) {
        sub.controller.add(SubscriptionNotification(
          method: method,
          params: Map<String, dynamic>.from(params),
        ));
      }
      return;
    }

    final handler = _notificationHandlers[method];
    if (handler != null) {
      try {
        handler(params);
      } catch (e) {
        _logger.debug('Error in notification handler: $e');
        _errorStreamController.add(
          McpError('Error in notification handler: $e'),
        );
      }
    } else {
      _logger.debug('No handler for notification: $method');
    }
  }

  /// Send a JSON-RPC request
  Future<dynamic> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final id = _requestId++;
    final completer = Completer<dynamic>();
    _requestCompleters[id] = completer;

    // Create a deep copy of params to avoid potential modification issues
    final Map<String, dynamic> safeParams = Map<String, dynamic>.from(params);

    // 2026-07-28 stateless core: there is no handshake, so every request
    // carries the client's identity + per-request capabilities in `_meta`
    // under the reserved `io.modelcontextprotocol/*` keys, plus the required
    // protocol version. Additive — the existing `_meta` (if the caller set
    // one, e.g. a progressToken) is preserved.
    if (_statelessMode) {
      safeParams['_meta'] = _statelessMeta(safeParams['_meta']);
    }

    final request = {
      'jsonrpc': McpProtocol.jsonRpcVersion,
      'id': id,
      'method': method,
      'params': safeParams,
    };

    try {
      _transport!.send(request);
    } catch (e) {
      _requestCompleters.remove(id);
      final error = McpError('Failed to send request: $e');
      _errorStreamController.add(error);
      throw error;
    }

    try {
      // Add timeout for requests
      final result = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _requestCompleters.remove(id);
          final error = McpError('Request timed out: $method');
          _errorStreamController.add(error);
          throw error;
        },
      );
      return result;
    } catch (e) {
      if (e is! McpError) {
        final error = McpError('Request failed: $e');
        _errorStreamController.add(error);
        throw error;
      }
      rethrow;
    }
  }

  /// Build the stateless-path `_meta` (reverse-DNS client info + per-request
  /// capabilities + protocol version), preserving any [existingMeta].
  Map<String, dynamic> _statelessMeta(Object? existingMeta) => McpRequestMeta.build(
        protocolVersion: McpProtocol.v2026_07_28,
        clientCapabilities: capabilities.toJson(),
        clientInfo: {
          'name': name,
          'version': version,
          if (description != null) 'description': description,
        },
        extra:
            existingMeta is Map ? Map<String, dynamic>.from(existingMeta) : null,
      );

  /// Maximum Multi-Round-Trip iterations before giving up (guards against a
  /// server that keeps returning `input_required`).
  static const int _mrtrMaxRounds = 16;

  /// 2026-07-28 Multi-Round-Trip driver (SEP-2577). Sends [method]+[params] and,
  /// while the stateless result is `input_required`, fulfills each embedded
  /// server input request (`sampling/createMessage` / `roots/list` /
  /// `elicitation/create`) with the client's registered handler, then re-issues
  /// the ORIGINAL request carrying the matching `inputResponses` + the echoed
  /// opaque `requestState`. Loops until a terminal (`complete`) result. On the
  /// legacy path (or a non-stateless client) this is a single `_sendRequest`.
  Future<Map<String, dynamic>> _sendRequestWithMrtr(
      String method, Map<String, dynamic> params) async {
    var currentParams = params;
    for (var round = 0; round < _mrtrMaxRounds; round++) {
      final raw = await _sendRequest(method, currentParams);
      final result = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      if (!_statelessMode ||
          McpResultType.of(result) != McpResultType.inputRequired) {
        return result;
      }
      final required = InputRequiredResult.fromJson(result);
      final inputResponses = <String, dynamic>{};
      for (final entry in required.inputRequests.entries) {
        final req = entry.value;
        final reqMethod = req['method'] as String?;
        if (reqMethod == null) {
          throw McpError('InputRequest `${entry.key}` is missing a method');
        }
        final handler = _requestHandlers[reqMethod];
        if (handler == null) {
          throw McpError(
              'No handler registered for server input request `$reqMethod`');
        }
        final reqParams = req['params'] is Map
            ? Map<String, dynamic>.from(req['params'] as Map)
            : <String, dynamic>{};
        inputResponses[entry.key] = await handler(reqParams);
      }
      // Re-issue the ORIGINAL request (params) with the MRTR fields added.
      currentParams = <String, dynamic>{
        ...params,
        if (inputResponses.isNotEmpty) 'inputResponses': inputResponses,
        if (required.requestState != null) 'requestState': required.requestState,
      };
    }
    throw McpError(
        'Multi-round-trip exceeded $_mrtrMaxRounds rounds for `$method`');
  }

  /// Open a 2026-07-28 `subscriptions/listen` stream (SEP-2577) — the stateless
  /// replacement for the `resources/subscribe` RPC + the HTTP GET SSE stream.
  ///
  /// Sends the request with the opt-in [filter]; the returned [Subscription]
  /// exposes the server's acknowledged (honored) filter, the stream of stamped
  /// notifications, and `cancel()` (which terminates the stream via
  /// `notifications/cancelled`). Stateless mode only.
  Future<Subscription> listen(SubscriptionFilter filter) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    if (!_statelessMode) {
      throw McpError(
          '`subscriptions/listen` requires the 2026-07-28 stateless mode');
    }
    final id = _requestId++;
    final ackCompleter = Completer<SubscriptionFilter>();
    final controller = StreamController<SubscriptionNotification>();
    _subscriptions[id] = _ClientSubscription(
      id: id,
      ackCompleter: ackCompleter,
      controller: controller,
    );

    final params = <String, dynamic>{
      'notifications': filter.toJson(),
      '_meta': _statelessMeta(null),
    };
    _transport!.send(<String, dynamic>{
      'jsonrpc': McpProtocol.jsonRpcVersion,
      'id': id,
      'method': 'subscriptions/listen',
      'params': params,
    });

    return Subscription(
      subscriptionId: id,
      acknowledged: ackCompleter.future,
      notifications: controller.stream,
      cancel: () {
        if (_subscriptions.containsKey(id)) {
          _sendNotification('notifications/cancelled', {'requestId': id});
        }
      },
    );
  }

  /// Send a JSON-RPC notification
  void _sendNotification(String method, Map<String, dynamic> params) {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final notification = {
      'jsonrpc': McpProtocol.jsonRpcVersion,
      'method': method,
      'params': params,
    };

    _transport!.send(notification);
  }
}

/// Internal holder for a live client-side `subscriptions/listen` stream.
class _ClientSubscription {
  final int id;
  final Completer<SubscriptionFilter> ackCompleter;
  final StreamController<SubscriptionNotification> controller;

  _ClientSubscription({
    required this.id,
    required this.ackCompleter,
    required this.controller,
  });
}

/// Result of a `server/discover` call (2026-07-28 stateless core).
///
/// Mirrors the draft schema `DiscoverResult` (extends `CacheableResult`): the
/// server's supported protocol versions, its capabilities, optional
/// natural-language instructions, and the cache hints ([ttlMs]/[cacheScope]).
class DiscoverResult {
  /// Protocol versions the server supports; the client picks one for
  /// subsequent requests.
  final List<String> supportedVersions;

  /// The server's advertised capabilities.
  final ServerCapabilities capabilities;

  /// Optional natural-language guidance describing the server (LLM
  /// system-prompt hint).
  final String? instructions;

  /// Cache TTL hint in milliseconds (`CacheableResult.ttlMs`), if present.
  final int? ttlMs;

  /// Cache scope hint (`"public"` / `"private"`), if present.
  final String? cacheScope;

  /// Self-reported server software identity from the result `_meta`
  /// (`io.modelcontextprotocol/serverInfo`), if present.
  final Map<String, dynamic>? serverInfo;

  const DiscoverResult({
    required this.supportedVersions,
    required this.capabilities,
    this.instructions,
    this.ttlMs,
    this.cacheScope,
    this.serverInfo,
  });
}

/// Reason for disconnection
enum DisconnectReason {
  /// Client explicitly disconnected
  clientDisconnected,

  /// Transport closed
  transportClosed,

  /// Transport encountered an error
  transportError,

  /// Server disconnected the client
  serverDisconnected,

  /// Session expired on the server
  sessionExpired,

  /// Unknown reason
  unknown,
}

/// Class to hold result of a tracked tool call
class ToolCallTracking {
  /// Operation ID for tracking progress
  final String? operationId;

  /// Result of the tool call
  final CallToolResult result;

  ToolCallTracking({this.operationId, required this.result});
}

// ============================================================================
// Deferred Loading Support Extension
// ============================================================================

/// Extension on Client for easy metadata access in deferred loading mode
extension ClientToolMetadataExtension on Client {
  /// Fetch tools and return metadata only
  /// Caches full tools in provided registry for later schema lookup
  ///
  /// Usage:
  /// ```dart
  /// final registry = ToolRegistry();
  /// final metadata = await client.listToolsMetadata(registry);
  /// // Use metadata for LLM context (token-efficient)
  /// // Later, use registry.getSchema(toolName) for full schema
  /// ```
  Future<List<ToolMetadata>> listToolsMetadata(ToolRegistry registry) async {
    final tools = await listTools();
    registry.cacheFromTools(tools);
    return registry.getAllMetadata();
  }
}
