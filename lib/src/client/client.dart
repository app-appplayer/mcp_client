import 'dart:async';
import 'dart:convert';

import '../../logger.dart';
import '../models/models.dart';
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

  /// Protocol version this client speaks on this connection.
  ///
  /// Settable per client because the peer decides what it supports: a build
  /// pinned to one revision cannot fall back to a version a server offers, and
  /// cannot be exercised against more than one revision.
  final String protocolVersion;

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

  /// 2026-07-28 has no `resources/subscribe`: [subscribeResource] keeps one
  /// `subscriptions/listen` whose filter names these URIs.
  final Set<String> _listenedResources = {};
  Subscription? _resourceListen;
  Future<void> _resourceListenChange = Future.value();

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

  /// Display name for the client (`clientInfo.title`, 2025-06-18+).
  final String? title;

  /// The client's website (`clientInfo.websiteUrl`, 2025-11-25+).
  final String? websiteUrl;

  /// Icons for the client (`clientInfo.icons`, 2025-11-25+).
  final List<McpIcon>? icons;

  /// How long a request waits for its response unless the request sets its
  /// own ([RequestOptions.timeout]). A progress notification for the request
  /// restarts the wait, but never past [maxRequestTimeout] from the start.
  final Duration requestTimeout;

  /// The longest any request waits, progress notwithstanding (lifecycle,
  /// timeouts: enforce a maximum regardless of progress).
  final Duration maxRequestTimeout;

  final Map<Object, void Function(ProgressNotificationParams)> _progressListeners = {};

  /// `clientInfo` as this client describes itself.
  Map<String, dynamic> get _clientInfo => {
        'name': name,
        'version': version,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (websiteUrl != null) 'websiteUrl': websiteUrl,
        if (icons != null) 'icons': [for (final i in icons!) i.toJson()],
      };

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
    this.title,
    this.websiteUrl,
    this.icons,
    this.capabilities = const ClientCapabilities(),
    String? protocolVersion,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxRequestTimeout = const Duration(minutes: 10),
  }) : protocolVersion = protocolVersion ?? McpProtocol.defaultVersion {
    // Default `roots/list` handler returns the locally registered roots.
    // Hosts may override with [onListRoots] for dynamic roots.
    _requestHandlers['roots/list'] = (_) async => {
          'roots': _roots.map((r) => r.toJson()).toList(),
        };

    // `ping` is answered by whichever side receives it, with an empty result.
    // Without this a server keepalive gets `Method not found` back.
    _requestHandlers['ping'] = (_) async => const {};
    _installTaskHandlers();
  }

  /// Connect the client to a transport.
  ///
  /// [era] picks the revision family:
  /// - [ProtocolEra.auto] (default): probe with `server/discover` (waiting
  ///   [eraProbeTimeout]); a modern answer selects 2026-07-28, anything else
  ///   the `initialize` handshake.
  /// - [ProtocolEra.modern]: 2026-07-28 — no handshake; every request carries
  ///   its `_meta` (protocol version, client info, capabilities) and, over
  ///   HTTP, `MCP-Protocol-Version: 2026-07-28`. Server capabilities come from
  ///   [discover].
  /// - [ProtocolEra.legacy]: the `initialize` handshake (2025-11-25 and
  ///   earlier).
  ///
  /// [statelessMode] is the 2.x form: `true` is [ProtocolEra.modern],
  /// `false` is [ProtocolEra.legacy]. Pass it or [era], not both.
  ///
  /// [onConnect] fires once the connection is ready.
  Future<void> connect(
    ClientTransport transport, {
    ProtocolEra era = ProtocolEra.auto,
    @Deprecated('Use era: ProtocolEra.modern (true) or ProtocolEra.legacy (false).')
    bool? statelessMode,
  }) async {
    if (statelessMode != null) {
      if (era != ProtocolEra.auto) {
        throw ArgumentError('Pass era or statelessMode, not both');
      }
      era = statelessMode ? ProtocolEra.modern : ProtocolEra.legacy;
    }
    if (_transport != null) {
      throw McpError('Client is already connected to a transport');
    }

    if (_connecting) {
      throw McpError('Client is already connecting to a transport');
    }

    _connecting = true;
    _statelessMode = era != ProtocolEra.legacy;
    _transport = transport;
    // `onError` is load-bearing. A transport reports a wire failure by adding
    // an error to this stream (an HTTP POST to a closed port, a dropped
    // socket). Listening without a handler left that error unhandled and the
    // request completers untouched, so a request on a dead endpoint waited out
    // its 30-second timeout instead of failing when the wire did.
    _transport!.onMessage.listen(_handleMessage, onError: _handleTransportError);
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
        _useModern();
        if (era == ProtocolEra.auto && !await _probeModern()) {
          _useLegacy();
          await initialize();
        }
      } else {
        await initialize();
      }
      _connecting = false;

      // Emit connection event after successful initialization
      if (_initialized && _serverInfo != null && _serverCapabilities != null) {
        _connectStreamController.add(
          Implementation.fromJson(Map<String, Object?>.from(_serverInfo!)),
        );
      }
    } catch (e) {
      _connecting = false;
      _errorStreamController.add(McpError('Initialization error: $e'));
      disconnect();
      rethrow;
    }
  }

  /// The era this client settled on for the connection.
  ProtocolEra get era => _statelessMode ? ProtocolEra.modern : ProtocolEra.legacy;

  /// How long the `server/discover` era probe waits before treating the
  /// server as legacy (an unknown pre-`initialize` request may get no answer).
  /// Null: 30 s on stdio — a server process may still be starting (compiling,
  /// even), and its silence then says nothing about its revision — and 5 s
  /// elsewhere. A legacy server normally answers the probe at once with an
  /// error, so the wait only matters for one that never answers.
  Duration? eraProbeTimeout;

  Duration get _eraProbeTimeout =>
      eraProbeTimeout ??
      (_transport is StdioClientTransport ? const Duration(seconds: 30) : const Duration(seconds: 5));

  void _useModern() {
    _statelessMode = true;
    _negotiatedProtocolVersion = McpProtocol.v2026_07_28;
    final tx = _transport;
    if (tx is StreamableHttpClientTransport) {
      tx.setProtocolVersion(McpProtocol.v2026_07_28);
    }
    _initialized = true;
  }

  void _useLegacy() {
    _statelessMode = false;
    _negotiatedProtocolVersion = null;
    final tx = _transport;
    if (tx is StreamableHttpClientTransport) tx.setProtocolVersion(null);
    _initialized = false;
  }

  /// Versioning, backward compatibility: probe with `server/discover` in the
  /// modern era. A `DiscoverResult` or a recognized modern error means a
  /// modern server (a modern error naming only legacy versions is answered
  /// by falling back to them); any other error, or no answer within
  /// [eraProbeTimeout], means a legacy server. The answer holds for this
  /// connection (the era is a property of the server).
  Future<bool> _probeModern() async {
    try {
      final result = await discover(options: RequestOptions(timeout: _eraProbeTimeout));
      final versions = result.has('supportedVersions') ? result.supportedVersions : const <String>[];
      if (versions.contains(McpProtocol.v2026_07_28)) return true;
      // Anything else is not a modern answer this client can use: a server
      // listing only legacy versions is spoken to with `initialize`.
      return false;
    } on McpError catch (e) {
      if (!_modernErrorCodes.contains(e.code)) return false;
      if (e.code != McpProtocol.errorUnsupportedProtocolVersion) return true;
      final supported = _supportedFrom(e);
      if (supported.contains(McpProtocol.v2026_07_28)) return true;
      final legacy = supported.where(McpProtocol.supportedVersions.contains);
      if (legacy.isEmpty) {
        throw McpError(
          'No protocol version in common: the server supports '
          '${supported.join(", ")}; this client ${McpProtocol.v2026_07_28}, '
          '${McpProtocol.supportedVersions.join(", ")}',
          code: e.code,
          data: e.data,
        );
      }
      return false;
    }
  }

  static const Set<int> _modernErrorCodes = {
    McpProtocol.errorHeaderMismatch,
    McpProtocol.errorMissingRequiredClientCapability,
    McpProtocol.errorUnsupportedProtocolVersion,
  };

  static List<String> _supportedFrom(McpError e) {
    final data = e.data;
    final supported = data is Map ? data['supported'] : null;
    return supported is List ? supported.whereType<String>().toList() : const [];
  }

  /// Fails everything in flight when the wire under it fails.
  ///
  /// Nothing will answer a request whose transport just reported an error, so
  /// the completers are resolved here rather than left to time out. This is
  /// what makes `connect` on an unreachable endpoint return an error at the
  /// speed the socket failed.
  void _handleTransportError(Object error) {
    final err =
        error is McpError ? error : McpError('Transport error: $error');
    if (!_errorStreamController.isClosed) _errorStreamController.add(err);
    if (_requestCompleters.isEmpty) return;
    final pending = List.of(_requestCompleters.values);
    _requestCompleters.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(err);
    }
  }

  /// Connect, retrying a failed attempt up to [maxRetries] times in all.
  ///
  /// A failed attempt closes its transport, so every attempt gets a fresh
  /// one from [openTransport].
  Future<void> connectWithRetry(
    Future<ClientTransport> Function() openTransport, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 2),
    ProtocolEra era = ProtocolEra.auto,
  }) async {
    for (var attempt = 1;; attempt++) {
      try {
        await connect(await openTransport(), era: era);
        return;
      } catch (e) {
        if (attempt >= maxRetries) {
          final error = McpError('Failed to connect after $maxRetries attempts: $e');
          _errorStreamController.add(error);
          throw error;
        }
        _logger.debug('Connection attempt $attempt failed: $e. Retrying in $delay');
        await Future<void>.delayed(delay);
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
      // Optional `Implementation` fields are emitted only when set, so older
      // peers see the shape they know.
      'clientInfo': _clientInfo,
      'capabilities': capabilities.toJson(),
    });

    if (response == null) {
      throw McpError('Failed to initialize: No response from server');
    }

    final serverProtoVersion = response['protocolVersion'];
    if (serverProtoVersion != protocolVersion) {
      _validateProtocolVersion(serverProtoVersion);
    }
    // Lifecycle, version negotiation: a version this client does not
    // support ends the connection.
    if (serverProtoVersion is! String ||
        !McpProtocol.supportedVersions.contains(serverProtoVersion)) {
      disconnect();
      throw McpError(
        'Server chose protocol version $serverProtoVersion, which this client '
        'does not support (${McpProtocol.supportedVersions.join(", ")})',
      );
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
    _negotiatedProtocolVersion = serverProtoVersion;
    // HTTP transports attach `MCP-Protocol-Version` to subsequent
    // requests when the negotiated revision is 2025-06-18+. Other
    // transports (stdio / SSE) ignore the header so we only forward
    // when the concrete transport exposes the setter.
    final tx = _transport;
    if (tx is StreamableHttpClientTransport) {
      tx.setProtocolVersion(serverProtoVersion);
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
  Future<DiscoverResult> discover({RequestOptions? options}) async {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }
    final response = await _sendRequest('server/discover', {}, options);
    if (response == null) {
      throw McpError('server/discover returned no result');
    }
    final map = Map<String, dynamic>.from(response as Map);
    final result = DiscoverResult.fromJson(map);
    final capsData = map['capabilities'];
    _serverCapabilities = ServerCapabilities.fromJson(
      capsData is Map ? Map<String, dynamic>.from(capsData) : {},
    );

    // ResultMetaObject may carry `serverInfo` (2026-07-28).
    final serverInfo = McpRequestMeta.readServerInfo(map['_meta']);
    if (serverInfo != null) {
      _serverInfo = serverInfo;
    }
    return result;
  }

  // ── Tasks extension (io.modelcontextprotocol/tasks, 2026-07-28) ──────────

  /// Whether the server advertised the tasks extension (from the last
  /// `initialize`/`discover`). Task calls only make sense when true.
  /// Extensions whose methods may be used: those the server advertised, or
  /// all this client knows while the server's capabilities are not yet known.
  Set<String> get _extensionsInUse =>
      _serverCapabilities == null || supportsTasks ? const {tasksExtensionId} : const {};

  bool get supportsTasks =>
      _serverCapabilities?.hasExtension(tasksExtensionId) ?? false;

  /// If a `tools/call` (or other) result is a `CreateTaskResult` — the
  /// extension's `resultType: "task"` or the 2025-11-25 core's nested
  /// `task` — returns the [Task]; otherwise null.
  Task? taskFromResult(Map<String, dynamic> result) =>
      McpResultType.of(result) == McpResultType.task || result['task'] is Map
          ? taskOf(result)
          : null;

  /// Poll a task's current state (`tasks/get`): the task plus, in the
  /// extension, `inputRequests` / `result` / `error` for its state.
  Future<GetTaskResult> getTask(String taskId, {Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    final response =
        await _sendRequest('tasks/get', _withMeta({'taskId': taskId}, meta), options);
    if (response == null) throw McpError('tasks/get returned no result');
    return GetTaskResult.fromJson(Map<String, dynamic>.from(response as Map));
  }

  /// Deliver input responses to an `input_required` task (`tasks/update`).
  /// [inputResponses] is keyed by the task's outstanding `inputRequests` keys.
  Future<void> updateTask(
      String taskId, Map<String, dynamic> inputResponses,
      {Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    await _sendRequest(
        'tasks/update',
        _withMeta(
            {'taskId': taskId, 'inputResponses': inputResponses}, meta), options);
  }

  /// Cancel a task (`tasks/cancel`). 2025-11-25 answers with the cancelled
  /// task; the 2026-07-28 extension only acknowledges (null).
  Future<Task?> cancelTask(String taskId, {Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!isConnected) throw McpError('Client is not connected to a transport');
    final response = Map<String, dynamic>.from(
        await _sendRequest('tasks/cancel', _withMeta({'taskId': taskId}, meta), options) as Map);
    return response['taskId'] is String ? Task.fromJson(response) : null;
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
  Future<List<Tool>> listTools({Map<String, dynamic>? meta, RequestOptions? options}) async {
    // Every page: the server decides the page size and signals more with
    // `nextCursor` (an empty string is a cursor, not the end).
    final all = <Tool>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await listToolsPage(cursor: cursor, meta: meta, options: options);
      all.addAll(page.tools);
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw McpError('`tools/list` repeated cursor "$cursor"');
      }
    } while (cursor != null);
    return all;
  }

  /// One page of `tools/list`: pass the previous page's `nextCursor` as
  /// [cursor] for the next one.
  Future<ListToolsResult> listToolsPage({String? cursor, Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    final response = await _sendRequest(
        'tools/list', _withMeta({if (cursor != null) 'cursor': cursor}, meta), options);
    var result = ListToolsResult.fromJson(Map<String, dynamic>.from(response as Map));
    // 2026-07-28 Streamable HTTP: a tool whose x-mcp-header annotations are
    // invalid is left out of the list (with a warning), the rest stay usable.
    if (_mirrorsParamHeaders) {
      final kept = <Tool>[];
      for (final tool in result.tools) {
        final annotations = mcpParamHeaders(tool.toJson()['inputSchema']);
        if (annotations.problem != null) {
          _logger.warning('Tool "${tool.name}" rejected: ${annotations.problem}');
          continue;
        }
        _toolParamHeaders[tool.name] = annotations.headers;
        kept.add(tool);
      }
      if (kept.length != result.tools.length) {
        result = ListToolsResult.fromJson({
          ...result.toJson(),
          'tools': [for (final t in kept) t.toJson()],
        });
      }
    }
    for (final tool in result.tools) {
      _rememberOutputSchema(tool);
      final execution = tool.toJson()['execution'];
      _toolTaskSupport[tool.name] =
          (execution is Map ? execution['taskSupport'] as String? : null) ?? 'forbidden';
    }
    return result;
  }

  /// Whether [callTool] checks `structuredContent` against the tool's
  /// `outputSchema` (from the last `tools/list`). Clients should validate
  /// structured results; a mismatch fails the call with [McpError].
  bool validateToolOutput = true;

  /// `x-mcp-header` annotations by tool name, from `tools/list`.
  final Map<String, List<McpParamHeader>> _toolParamHeaders = {};

  /// Whether tool parameters are mirrored into `Mcp-Param-*` headers:
  /// 2026-07-28 over Streamable HTTP (other transports ignore them).
  bool get _mirrorsParamHeaders => _statelessMode && _transport is StreamableHttpClientTransport;

  /// `execution.taskSupport` by tool name, from `tools/list`.
  final Map<String, String> _toolTaskSupport = {};

  /// Output schema validators by tool name, from `tools/list`.
  final Map<String, JsonSchemaValidator> _outputValidators = {};

  void _rememberOutputSchema(Tool tool) {
    _outputValidators.remove(tool.name);
    if (!tool.has('outputSchema')) return;
    try {
      _outputValidators[tool.name] =
          JsonSchemaValidator(tool.outputSchema);
    } on JsonSchemaException catch (e) {
      _logger.warning('Tool "${tool.name}" has an outputSchema this client cannot use: ${e.message}');
    }
  }

  void _checkToolOutput(String name, CallToolResult result) {
    if (!validateToolOutput || result.isError == true) return;
    final validator = _outputValidators[name];
    if (validator == null) return;
    final json = result.toJson();
    if (!json.containsKey('structuredContent')) {
      throw McpError('Tool "$name" declared an outputSchema but returned no structuredContent');
    }
    final check = validator.validate(json['structuredContent']);
    if (!check.valid) {
      throw McpError('Tool "$name" returned structuredContent that does not match its outputSchema: '
          '${check.errors.join('; ')}', data: [for (final e in check.errors) e.toJson()]);
    }
  }


  /// Call a tool on the server
  ///
  /// Every request method takes an optional `meta`, sent as the request
  /// `_meta`. It carries application context the server reads per request
  /// (e.g. a forwarding host relaying its caller's identity); use namespaced
  /// keys (`prefix/name`). Reserved `io.modelcontextprotocol/*` keys the
  /// client writes on the stateless path always win.
  Future<CallToolResult> callTool(
    String name,
    Map<String, dynamic> toolArguments, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    // Create a clean params map with properly typed values
    final Map<String, dynamic> params = _withMeta({
      'name': name,
      'arguments': Map<String, dynamic>.from(toolArguments),
    }, meta);

    if (_mirrorsParamHeaders) {
      if (!_toolParamHeaders.containsKey(name)) await listTools();
      try {
        return await _callToolOnce(name, params, options);
      } on McpError catch (e) {
        if (e.code != McpProtocol.errorHeaderMismatch) rethrow;
        // The tool's annotations may have changed: read them again, retry.
        _toolParamHeaders.remove(name);
        await listTools();
        return _callToolOnce(name, params, options);
      }
    }

    // 2025-11-25: a tool that runs only as a task is always called as one.
    if (!_statelessMode && _serverToolTasks && _toolTaskSupport[name] == 'required') {
      final task = await callToolAsTask(name, toolArguments, meta: meta, options: options);
      final result = CallToolResult.fromJson(await taskResult(task.taskId, options: options));
      _checkToolOutput(name, result);
      return result;
    }

    return _callToolOnce(name, params, options);
  }

  Future<CallToolResult> _callToolOnce(
      String name, Map<String, dynamic> params, RequestOptions? options) async {
    // 2026-07-28 (SEP-2577): a stateless `tools/call` may return
    // `input_required`; the MRTR driver fulfills the server's input requests and
    // re-issues until a terminal result. Legacy path = a single request.
    final response = _statelessMode
        ? await _sendRequestWithMrtr('tools/call', params, options)
        : await _sendRequest('tools/call', params, options);
    // Tasks extension: the server may answer with a task; it is followed
    // to its end here, so callers see the final result.
    final finalResponse = McpResultType.of(response) == McpResultType.task
        ? await _followExtensionTask(Map<String, dynamic>.from(response), options)
        : response;
    final result = CallToolResult.fromJson(finalResponse);
    _checkToolOutput(name, result);
    return result;
  }

  bool get _serverToolTasks {
    final requests = _serverCapabilities?.tasks?['requests'];
    final tools = requests is Map ? requests['tools'] : null;
    return tools is Map && tools['call'] != null;
  }

  /// Call [name] as a 2025-11-25 task: the answer is the task, the result
  /// comes from [taskResult]. Only where the server accepts tool tasks and
  /// the tool allows them (tools/list is read when the tool is unknown).
  Future<Task> callToolAsTask(String name, Map<String, dynamic> toolArguments,
      {int? ttl, Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (_statelessMode) {
      throw McpError('In 2026-07-28 the server decides which calls become tasks; use callTool');
    }
    if (!_serverToolTasks) {
      throw McpError('The server does not accept task-augmented tool calls');
    }
    if (!_toolTaskSupport.containsKey(name)) await listTools();
    final support = _toolTaskSupport[name] ?? 'forbidden';
    if (support == 'forbidden') throw McpError('Tool "$name" does not run as a task');
    final response = await _sendRequest('tools/call', _withMeta({
      'name': name,
      'arguments': Map<String, dynamic>.from(toolArguments),
      'task': {if (ttl != null) 'ttl': ttl},
    }, meta), options);
    final created = Map<String, dynamic>.from(response as Map);
    if (created['task'] is! Map) throw McpError('The server did not answer with a task');
    return taskOf(created);
  }

  /// 2025-11-25 `tasks/result`: wait for the task to end and return what the
  /// underlying request returned (its JSON-RPC error is thrown as [McpError]).
  Future<Map<String, dynamic>> taskResult(String taskId, {RequestOptions? options}) async {
    final response = await _sendRequest('tasks/result', {'taskId': taskId},
        options ?? const RequestOptions(timeout: Duration(hours: 1)));
    final result = Map<String, dynamic>.from(response as Map);
    final meta = result['_meta'];
    if (meta is Map) {
      final rest = Map<String, dynamic>.from(meta)..remove('io.modelcontextprotocol/related-task');
      if (rest.isEmpty) {
        result.remove('_meta');
      } else {
        result['_meta'] = rest;
      }
    }
    return result;
  }

  /// 2025-11-25 `tasks/list`: one page of this client's tasks.
  Future<ListTasksResult> listTasksPage({String? cursor, RequestOptions? options}) async {
    final response = await _sendRequest('tasks/list', {if (cursor != null) 'cursor': cursor}, options);
    return ListTasksResult.fromJson(Map<String, dynamic>.from(response as Map));
  }

  /// Follow an extension task to its end: poll `tasks/get` at the server's
  /// interval, answer its input requests through this client's handlers with
  /// `tasks/update` (each key once), and return the final result. A failed
  /// task throws its JSON-RPC error; a cancelled or expired one throws.
  Future<Map<String, dynamic>> _followExtensionTask(
      Map<String, dynamic> created, RequestOptions? options) async {
    final taskId = created['taskId'] as String;
    final answered = <String>{};
    var task = created;
    while (true) {
      switch (task['status']) {
        case 'completed':
          return Map<String, dynamic>.from(task['result'] as Map? ?? const {});
        case 'failed':
          final error = task['error'] is Map ? task['error'] as Map : const {};
          throw McpError(error['message'] as String? ?? 'Task failed',
              code: error['code'] as int?, data: error['data']);
        case 'cancelled':
          throw McpError('Task $taskId was cancelled');
        case 'input_required':
          final requests = task['inputRequests'];
          final responses = <String, dynamic>{};
          for (final e in (requests is Map ? requests : const {}).entries) {
            if (!answered.add('${e.key}')) continue;
            final req = Map<String, dynamic>.from(e.value as Map);
            try {
              responses['${e.key}'] = await _fulfilInput(
                  req['method'] as String, Map<String, dynamic>.from(req['params'] as Map? ?? {}));
            } on McpError {
              await cancelTask(taskId);
              rethrow;
            }
          }
          if (responses.isNotEmpty) await updateTask(taskId, responses);
      }
      final ttl = task['ttlMs'];
      final createdAt = DateTime.tryParse('${task['createdAt']}');
      if (ttl is int && createdAt != null && DateTime.now().isAfter(createdAt.add(Duration(milliseconds: ttl)))) {
        throw McpError('Task $taskId outlived its ttl without finishing');
      }
      final interval = task['pollIntervalMs'];
      await Future<void>.delayed(Duration(milliseconds: interval is int && interval > 0 ? interval : 1000));
      task = Map<String, dynamic>.from(
          (await _sendRequest('tasks/get', {'taskId': taskId}, options)) as Map);
    }
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
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    final params = _withMeta({
      'name': name,
      'arguments': Map<String, dynamic>.from(arguments),
      'trackProgress': trackProgress,
    }, meta);

    final response = await _sendRequest('tools/call', params, options);
    final operationId = response['operationId'] as String?;
    final result = CallToolResult.fromJson(response);
    _checkToolOutput(name, result);

    return ToolCallTracking(operationId: operationId, result: result);
  }

  /// Cancel an in-flight server-side operation.
  ///
  /// Per spec, cancellation is a NOTIFICATION (`notifications/cancelled`),
  /// not a request — fire-and-forget with `requestId` and an optional
  /// `reason`.
  ///
  /// Only a request this client sent and is still waiting on can be
  /// cancelled; its call then fails, and a late response is ignored.
  /// (A call made with [RequestOptions.cancel] is cancelled the same way.)
  void notifyCancelled(Object requestId, {String? reason}) {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    final completer = _requestCompleters.remove(requestId);
    if (completer == null) {
      throw ArgumentError.value(requestId, 'requestId', 'no request of this client is in flight with that id');
    }
    _cancelOnWire(requestId, reason);
    if (!completer.isCompleted) completer.completeError(McpError('Request cancelled'));
  }

  /// Tell the server request [id] is cancelled: on 2026-07-28 Streamable
  /// HTTP by closing the request's exchange (no notification is defined
  /// there), elsewhere with `notifications/cancelled`.
  void _cancelOnWire(Object id, String? reason) {
    final transport = _transport;
    if (_statelessMode && transport is StreamableHttpClientTransport) {
      transport.abortRequest(id);
      return;
    }
    _sendNotification('notifications/cancelled', {
      'requestId': id,
      if (reason != null) 'reason': reason,
    });
  }

  /// Report progress on an in-flight server-initiated request (spec
  /// `notifications/progress`). [progressToken] is the token the server
  /// sent in the original request's `_meta.progressToken`.
  ///
  /// Only for a server request still being handled, and only with a value
  /// greater than the last one sent for that token.
  void notifyProgress(
    dynamic progressToken,
    double progress, {
    double? total,
    String? message,
  }) {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    if (!_incomingProgress.containsKey(progressToken)) {
      throw ArgumentError.value(progressToken, 'progressToken', 'no server request in flight with that token');
    }
    final last = _incomingProgress[progressToken];
    if (last != null && progress <= last) {
      throw ArgumentError.value(progress, 'progress', 'must increase (last was $last)');
    }
    _incomingProgress[progressToken] = progress;
    _sendNotification('notifications/progress', {
      'progressToken': progressToken,
      'progress': progress,
      if (total != null) 'total': total,
      if (message != null) 'message': message,
    });
  }

  /// List available resources on the server
  Future<List<Resource>> listResources({Map<String, dynamic>? meta, RequestOptions? options}) async {
    // Every page: the server decides the page size and signals more with
    // `nextCursor` (an empty string is a cursor, not the end).
    final all = <Resource>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await listResourcesPage(cursor: cursor, meta: meta, options: options);
      all.addAll(page.resources);
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw McpError('`resources/list` repeated cursor "$cursor"');
      }
    } while (cursor != null);
    return all;
  }

  /// One page of `resources/list`: pass the previous page's `nextCursor` as
  /// [cursor] for the next one.
  Future<ListResourcesResult> listResourcesPage({String? cursor, Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest(
        'resources/list', _withMeta({if (cursor != null) 'cursor': cursor}, meta), options);
    return ListResourcesResult.fromJson(Map<String, dynamic>.from(response as Map));
  }


  /// Read a resource from the server
  Future<ReadResourceResult> readResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final params = _withMeta({'uri': uri}, meta);
    final response = _statelessMode
        ? await _sendRequestWithMrtr('resources/read', params, options)
        : await _sendRequest('resources/read', params, options);

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
    Map<String, dynamic> params, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
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

    return await readResource(uri, meta: meta, options: options);
  }

  /// Subscribe to a resource
  Future<void> subscribeResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    if (_statelessMode) {
      // 2026-07-28: the same subscription, on that revision's mechanism.
      if (_listenedResources.add(uri)) await _relistenResources(added: uri);
      return;
    }
    await _sendRequest('resources/subscribe', _withMeta({'uri': uri}, meta), options);
  }

  /// Reopen the resource listen stream for [_listenedResources]: the new
  /// stream first, then the old one closed, so no update falls between.
  /// [added] must be among what the server agreed to watch.
  Future<void> _relistenResources({String? added}) {
    final change = _resourceListenChange.then((_) async {
      final previous = _resourceListen;
      if (_listenedResources.isEmpty) {
        _resourceListen = null;
        previous?.cancel();
        return;
      }
      Subscription? opened;
      final SubscriptionFilter honored;
      try {
        opened = await _listen(
          SubscriptionFilter(resourceSubscriptions: _listenedResources.toList()),
          forwardToHandlers: true,
        );
        honored = await opened.acknowledged;
      } catch (_) {
        // The new stream did not come up: the previous one (without [added])
        // stays in force, so [added] is not subscribed.
        opened?.cancel();
        if (added != null) _listenedResources.remove(added);
        rethrow;
      }
      final next = opened;
      _resourceListen = next;
      previous?.cancel();
      if (added != null && !(honored.resourceSubscriptions ?? const []).contains(added)) {
        _listenedResources.remove(added);
        throw McpError('The server does not watch $added', code: McpProtocol.errorInvalidParams);
      }
    });
    _resourceListenChange = change.catchError((Object _) {});
    return change;
  }

  /// Unsubscribe from a resource
  Future<void> unsubscribeResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    if (_statelessMode) {
      if (_listenedResources.remove(uri)) await _relistenResources();
      return;
    }
    await _sendRequest('resources/unsubscribe', _withMeta({'uri': uri}, meta), options);
  }

  /// List resource templates on the server
  Future<List<ResourceTemplate>> listResourceTemplates({Map<String, dynamic>? meta, RequestOptions? options}) async {
    // Every page: the server decides the page size and signals more with
    // `nextCursor` (an empty string is a cursor, not the end).
    final all = <ResourceTemplate>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await listResourceTemplatesPage(cursor: cursor, meta: meta, options: options);
      all.addAll(page.resourceTemplates);
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw McpError('`resources/templates/list` repeated cursor "$cursor"');
      }
    } while (cursor != null);
    return all;
  }

  /// One page of `resources/templates/list`: pass the previous page's `nextCursor` as
  /// [cursor] for the next one.
  Future<ListResourceTemplatesResult> listResourceTemplatesPage({String? cursor, Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest(
        'resources/templates/list', _withMeta({if (cursor != null) 'cursor': cursor}, meta), options);
    return ListResourceTemplatesResult.fromJson(Map<String, dynamic>.from(response as Map));
  }


  /// List available prompts on the server
  Future<List<Prompt>> listPrompts({Map<String, dynamic>? meta, RequestOptions? options}) async {
    // Every page: the server decides the page size and signals more with
    // `nextCursor` (an empty string is a cursor, not the end).
    final all = <Prompt>[];
    final seen = <String>{};
    String? cursor;
    do {
      final page = await listPromptsPage(cursor: cursor, meta: meta, options: options);
      all.addAll(page.prompts);
      cursor = page.nextCursor;
      if (cursor != null && !seen.add(cursor)) {
        throw McpError('`prompts/list` repeated cursor "$cursor"');
      }
    } while (cursor != null);
    return all;
  }

  /// One page of `prompts/list`: pass the previous page's `nextCursor` as
  /// [cursor] for the next one.
  Future<ListPromptsResult> listPromptsPage({String? cursor, Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!_statelessMode && _serverCapabilities?.prompts != true) {
      throw McpError('Server does not support prompts');
    }

    final response = await _sendRequest(
        'prompts/list', _withMeta({if (cursor != null) 'cursor': cursor}, meta), options);
    return ListPromptsResult.fromJson(Map<String, dynamic>.from(response as Map));
  }


  /// Get a prompt from the server
  ///
  /// [meta] is positional because [promptArguments] already is (Dart does not
  /// mix optional positional and named parameters).
  Future<GetPromptResult> getPrompt(
    String name, [
    Map<String, dynamic>? promptArguments,
    Map<String, dynamic>? meta,
    RequestOptions? options,
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

    final request = _withMeta(params, meta);
    final response = _statelessMode
        ? await _sendRequestWithMrtr('prompts/get', request, options)
        : await _sendRequest('prompts/get', request, options);
    return GetPromptResult.fromJson(response);
  }

  /// Register a handler for server-initiated `sampling/createMessage`
  /// requests. The driver app (Claude Desktop / Claude Code / a vibe-style
  /// IDE) fulfils the prompt with its own LLM and returns the spec
  /// `CreateMessageResult` (`role`, `content`, `model`, optional
  /// `stopReason`).
  ///
  /// The client answers only when it declared `sampling` in its
  /// [ClientCapabilities] (`ClientCapabilities(sampling: true)`); otherwise
  /// the request is refused, as the specification requires.
  void onSamplingRequest(
    Future<CreateMessageResult> Function(CreateMessageRequestParams request) handler,
  ) {
    _requestHandlers['sampling/createMessage'] = (params) async {
      final result = await handler(CreateMessageRequestParams.fromJson(params));
      return result.toJson();
    };
  }

  /// Map-based variant of [onSamplingRequest]. Receives the request's
  /// params as a raw map and must return the raw `CreateMessageResult` map.
  ///
  /// Exists so generic adapters (notably `mcp_llm`'s `LlmClientAdapter`)
  /// can register a handler without importing the typed
  /// [CreateMessageRequestParams] / [CreateMessageResult] models — the typed
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
  /// The client answers only when it declared `elicitation` in its
  /// [ClientCapabilities] (`elicitation: true`, or `elicitationForm` /
  /// `elicitationUrl`); otherwise the request is refused.
  void onElicitationRequest(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) {
    _requestHandlers['elicitation/create'] = handler;
  }

  /// Typed variant of [onElicitationRequest]. The handler receives the
  /// request params — [ElicitRequestFormParams] (form mode; each field of
  /// `requestedSchema.properties` reads as a [PrimitiveSchemaDefinition]) or
  /// [ElicitRequestURLParams] (`mode: "url"`, 2025-11-25) — and returns an
  /// [ElicitResult].
  ///
  /// This is a convenience over the raw-map path; the wire behavior is
  /// identical. Registering either handler overrides the other (both bind
  /// the same `elicitation/create` slot). As with [onElicitationRequest],
  /// the client answers only when it declared `elicitation` in its
  /// [ClientCapabilities].
  void onElicitationRequestTyped(
    Future<ElicitResult> Function(ElicitRequestParams request) handler,
  ) {
    _requestHandlers['elicitation/create'] = (params) async {
      final res = await handler(ElicitRequestParams.fromJson(params));
      return res.toJson();
    };
  }

  /// Register a custom handler for server-initiated `roots/list` requests.
  /// By default the client responds with the locally configured [roots]
  /// list — supply this to override. Either way the client answers only when
  /// it declared `roots` in its [ClientCapabilities].
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

  /// Add a root to the client's local list. When the client declared
  /// `rootsListChanged`, the server is told with
  /// `notifications/roots/list_changed` (not on 2026-07-28, which has no
  /// such notification).
  ///
  /// A root is a `file://` URI (client/roots) with no `..` segments, so a
  /// server cannot be pointed outside it.
  void addRoot(Root root) {
    final uri = Uri.tryParse(root.uri);
    // Dart normalizes dot segments away, so the raw text is checked.
    final traversal = RegExp(r'(^|/)(\.\.|%2[eE]%2[eE])(/|$)').hasMatch(root.uri);
    if (uri == null || uri.scheme != 'file' || traversal) {
      throw ArgumentError.value(root.uri, 'root.uri', 'a root must be a file:// URI without ".." segments');
    }
    if (_roots.any((r) => r.uri == root.uri)) {
      throw McpError('Root with URI "${root.uri}" already exists');
    }
    _roots.add(root);
    _notifyRootsChanged();
  }

  /// `notifications/roots/list_changed`, sent when this client declared
  /// `roots.listChanged` on a revision that has it.
  void _notifyRootsChanged() {
    if (!isConnected || !_initialized || _statelessMode) return;
    if (!capabilities.rootsListChanged) return;
    _sendNotification('notifications/roots/list_changed', {});
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
    _notifyRootsChanged();
  }

  /// Set the logging level for the server
  ///
  /// In the modern era (2026-07-28) there is no session to set: the level is
  /// sent as `_meta` logLevel on every later request instead.
  Future<void> setLoggingLevel(McpLogLevel level,
      {Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    if (_statelessMode) {
      _logLevel = level;
      return;
    }

    // Spec method name is camelCase: `logging/setLevel`.
    await _sendRequest(
        'logging/setLevel', _withMeta({'level': level.name}, meta), options);
  }

  McpLogLevel? _logLevel;

  /// Sends `ping` and completes when the peer answers.
  ///
  /// The result is empty by definition; this is a liveness probe, so the value
  /// is that it returned at all. 2026-07-28 has no `ping`: refused here
  /// (-32601) rather than asked of a server that cannot answer it.
  Future<void> ping({Map<String, dynamic>? meta, RequestOptions? options}) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    if (_statelessMode) {
      throw McpError('ping is not part of protocol ${McpProtocol.v2026_07_28}',
          code: McpProtocol.errorMethodNotFound);
    }
    await _sendRequest('ping', _withMeta(const {}, meta), options);
  }

  /// Requests completion candidates for one argument of a prompt or resource
  /// reference (`completion/complete`).
  ///
  /// [ref] is the reference being completed, e.g.
  /// `{'type': 'ref/prompt', 'name': 'greet'}` or
  /// `{'type': 'ref/resource', 'uri': 'test://item/{id}'}`.
  /// [argument] is `{'name': ..., 'value': ...}` — the partial value typed so
  /// far. [context] optionally carries already-resolved arguments.
  Future<CompleteResult> complete(
    Map<String, dynamic> ref,
    Map<String, dynamic> argument, {
    Map<String, dynamic>? context,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }
    final result = await _sendRequest(
        'completion/complete',
        _withMeta({
          'ref': ref,
          'argument': argument,
          if (context != null) 'context': context,
        }, meta), options);
    return CompleteResult.fromJson(result);
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

  /// Register a handler for `notifications/resources/updated` that carries
  /// the new content: the handler gets the resource's URI and its contents.
  /// A notification without content (the usual case) does not reach it — use
  /// [onResourceUpdated] for those.
  void onResourceContentUpdated(
    Function(String uri, ResourceContents content) handler,
  ) {
    onNotification(McpProtocol.methodResourceUpdated, (params) {
      final uri = params['uri'] as String;
      final contentData = params['content'];
      if (contentData is! Map) return;
      handler(uri, ResourceContents.fromJson(Map<String, Object?>.from(contentData)));
    });
  }

  /// Register a handler for progress updates from the server (the 2.x
  /// form).
  ///
  /// The handler is called with the notification's `progressToken` (as a
  /// string), its `progress` and its `message` (`''` when absent). Use
  /// [onProgressNotification] for `total` and `_meta`.
  void onProgress(
    Function(String progressToken, double progress, String message) handler,
  ) {
    onProgressNotification((p) =>
        handler('${p.progressToken}', p.progress.toDouble(), p.message ?? ''));
  }

  /// Register a handler for progress updates from the server: the whole
  /// `notifications/progress` params (token, progress, total, message).
  void onProgressNotification(void Function(ProgressNotificationParams progress) handler) {
    onNotification(McpProtocol.methodProgress, (params) {
      handler(ProgressNotificationParams.fromJson(Map<String, Object?>.from(params)));
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

  Timer? _keepAlive;

  /// Ping the server every [interval] (basic/utilities/ping: implementations
  /// should check connection health periodically, at a configurable rate).
  /// A ping not answered within [timeout] is missed; [maxMissed] misses in a
  /// row are a connection failure: it is logged and the client disconnects
  /// with [DisconnectReason.pingTimeout]. An answered ping resets the count.
  /// Off unless started; revisions without `ping` (2026-07-28) refuse it.
  void startKeepAlive(
    Duration interval, {
    Duration timeout = const Duration(seconds: 10),
    int maxMissed = 1,
  }) {
    if (_statelessMode) {
      throw McpError('ping is not part of protocol ${McpProtocol.v2026_07_28}',
          code: McpProtocol.errorMethodNotFound);
    }
    if (maxMissed < 1) throw ArgumentError.value(maxMissed, 'maxMissed', 'must be at least 1');
    stopKeepAlive();
    var missed = 0;
    _keepAlive = Timer.periodic(interval, (_) async {
      try {
        await ping(options: RequestOptions(timeout: timeout));
        missed = 0;
      } on McpError catch (e) {
        if (_transport == null) return;
        _logger.warning('Keep-alive ping failed (${++missed}/$maxMissed): ${e.message}');
        if (missed < maxMissed) return;
        final transport = _transport!;
        _transport = null;
        _disconnectStreamController.add(DisconnectReason.pingTimeout);
        transport.close();
        _onDisconnect();
      }
    });
  }

  /// Stop [startKeepAlive] pings.
  void stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  /// Dispose client resources
  void dispose() {
    disconnect();

    // Close all stream controllers
    _messageController.close();
    _connectStreamController.close();
    _disconnectStreamController.close();
    _errorStreamController.close();
    _elicitationCompleteController.close();
  }

  /// Handle transport disconnection
  void _onDisconnect() {
    _transport = null;
    _initialized = false;
    stopKeepAlive();
    _listenedResources.clear();
    _resourceListen = null;

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
    final Object? parsed;
    try {
      parsed = rawMessage is String ? jsonDecode(rawMessage) : rawMessage;
    } catch (e) {
      _logger.debug('Error parsing message: $e');
      _errorStreamController.add(McpError('Error parsing message: $e'));
      return;
    }
    // Base protocol (2025-03-26): a batch must be accepted. Requests in it are
    // answered together, as one array.
    if (parsed is List) {
      unawaited(_handleBatch(parsed));
      return;
    }
    final message = _accept(parsed);
    if (message != null) _messageController.add(message);
  }

  Future<void> _handleBatch(List<Object?> batch) async {
    final answers = <Future<Map<String, dynamic>?>>[];
    for (final item in batch) {
      final message = _accept(item, answers: answers);
      if (message == null) continue;
      if (message.isRequest) {
        answers.add(_answerIncoming(message));
      } else {
        _messageController.add(message);
      }
    }
    final out = [for (final a in await Future.wait(answers)) if (a != null) a];
    if (out.isNotEmpty) _transport?.send(out);
  }

  /// One decoded message checked against the JSON-RPC 2.0 envelope as MCP
  /// narrows it: `jsonrpc` "2.0", a request id that is a string or an
  /// integer, object params, exactly one of result and error. A malformed
  /// request is answered with Invalid Request (into [answers] inside a
  /// batch); a malformed response is reported on [onError] and dropped.
  JsonRpcMessage? _accept(Object? item, {List<Future<Map<String, dynamic>?>>? answers}) {
    final problem = _envelopeProblem(item);
    if (problem == null) {
      return JsonRpcMessage.fromJson(Map<String, dynamic>.from(item as Map));
    }
    final map = item is Map ? item : null;
    final isResponse = map != null &&
        !map.containsKey('method') &&
        (map.containsKey('result') || map.containsKey('error'));
    if (isResponse) {
      _logger.debug('Dropping malformed response: $problem');
      _errorStreamController.add(McpError('Malformed response from server: $problem'));
      return null;
    }
    final id = map?['id'];
    final answer = _errorMessage(id is String || id is int ? id : null,
        code: McpProtocol.errorInvalidRequest, message: 'Invalid Request: $problem');
    if (answers != null) {
      answers.add(Future.value(answer));
    } else {
      _transport?.send(answer);
    }
    return null;
  }

  static String? _envelopeProblem(Object? item) {
    if (item is! Map) return 'not a JSON object';
    if (item['jsonrpc'] != '2.0') return '"jsonrpc" must be "2.0"';
    final id = item['id'];
    final idOk = id is String || id is int;
    if (item.containsKey('method')) {
      if (item['method'] is! String) return '"method" must be a string';
      if (item.containsKey('id') && !idOk) {
        return 'a request id must be a string or an integer';
      }
      if (item.containsKey('params') && item['params'] is! Map) {
        return '"params" must be an object';
      }
      return null;
    }
    final hasResult = item.containsKey('result');
    final hasError = item.containsKey('error');
    if (hasResult == hasError) {
      return 'a response must carry exactly one of "result" and "error"';
    }
    if (hasResult && !idOk) return 'a result response needs a string or integer id';
    if (hasError) {
      final error = item['error'];
      if (error is! Map || error['code'] is! int || error['message'] is! String) {
        return 'an error needs an integer "code" and a string "message"';
      }
      if (id != null && !idOk) return 'an error response id must be a string or an integer';
    }
    return null;
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
    final answer = await _answerIncoming(request);
    if (answer != null) _transport?.send(answer);
  }

  /// Progress tokens of server requests being handled, with the last value
  /// sent for each.
  final Map<Object?, double?> _incomingProgress = {};

  // ── Tasks this client runs for the server (2025-11-25 core) ───────────

  final McpTaskStore _taskStore = McpTaskStore();
  bool _taskHandlersInstalled = false;

  /// Whether this client declared `tasks.requests` for [method]
  /// (`sampling/createMessage`, `elicitation/create`).
  bool _acceptsTaskFor(String method) {
    if (_statelessMode) return false;
    final requests = capabilities.tasks?['requests'];
    if (requests is! Map) return false;
    final parts = method.split('/');
    final group = requests[parts.first];
    return group is Map && group[parts.last] != null;
  }

  /// Answer `tasks/*` from the server when tasks are declared.
  void _installTaskHandlers() {
    if (_taskHandlersInstalled || capabilities.tasks == null) return;
    _taskHandlersInstalled = true;
    McpTaskRecord found(Map<String, dynamic> p) {
      final task = _taskStore.get(p['taskId'] as String?, owner: null);
      if (task == null) throw McpError('Failed to retrieve task: Task not found', code: McpProtocol.errorInvalidParams);
      return task;
    }

    _requestHandlers['tasks/get'] = (p) async => found(p).toTaskJson();
    _requestHandlers['tasks/result'] = (p) async {
      final task = found(p);
      await task.whenTerminal;
      if (task.error != null) {
        throw McpError(task.error!['message'] as String, code: task.error!['code'] as int, data: task.error!['data']);
      }
      if (task.result == null) throw McpError('Task ${task.taskId} was cancelled', code: McpProtocol.errorInternal);
      return {
        ...task.result!,
        '_meta': {
          if (task.result!['_meta'] is Map) ...Map<String, dynamic>.from(task.result!['_meta'] as Map),
          'io.modelcontextprotocol/related-task': {'taskId': task.taskId},
        },
      };
    };
    if (capabilities.tasks!['list'] != null) {
      _requestHandlers['tasks/list'] = (p) async => {
            'tasks': [for (final t in _taskStore.list(owner: null)) t.toTaskJson()],
          };
    }
    if (capabilities.tasks!['cancel'] != null) {
      _requestHandlers['tasks/cancel'] = (p) async {
        final task = found(p);
        if (task.isTerminal) {
          throw McpError("Cannot cancel task: already in terminal status '${task.status}'",
              code: McpProtocol.errorInvalidParams);
        }
        _taskStore.cancel(task, statusMessage: 'The task was cancelled by request.');
        return task.toTaskJson();
      };
    }
    _taskStore.changes.listen((task) {
      if (_transport == null || !_initialized) return;
      _sendNotification('notifications/tasks/status', task.toTaskJson());
    });
  }

  Map<String, dynamic> _startClientTask(
      Object id, String method, Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler,
      Map<String, dynamic> params) {
    final ttl = (params['task'] as Map)['ttl'];
    final task = _taskStore.create(
        owner: null, flavor: McpTaskFlavor.core, method: method, requestedTtlMs: ttl is int ? ttl : null);
    final taskParams = Map<String, dynamic>.from(params)..remove('task');
    unawaited(() async {
      try {
        final result = await handler(taskParams);
        if (method == 'elicitation/create') {
          final problem = _elicitationAnswerProblem(taskParams, result);
          if (problem != null) {
            _taskStore.fail(task, {'code': McpProtocol.errorInternal, 'message': problem});
            return;
          }
        }
        _taskStore.complete(task, result);
      } on McpUserRejected catch (e) {
        _taskStore.fail(task, {'code': -1, 'message': e.message});
      } catch (e) {
        _taskStore.fail(task, {'code': McpProtocol.errorInternal, 'message': 'Handler error: $e'});
      }
    }());
    return {'jsonrpc': '2.0', 'id': id, 'result': {'task': task.toTaskJson()}};
  }

  /// Server requests being handled, by id; true once the server cancelled it.
  final Map<Object, bool> _incomingCancelled = {};

  /// The response to a server request, or null when the server cancelled it
  /// meanwhile (cancellation: the receiver sends no response).
  Future<Map<String, dynamic>?> _answerIncoming(JsonRpcMessage request) async {
    final method = request.method;
    final id = request.id;
    if (method == null || id == null) return null;
    final handler = _requestHandlers[method];
    final revision = _statelessMode ? McpProtocol.v2026_07_28 : _negotiatedProtocolVersion;
    final defined = revision == null
        ? null
        : mcpMethodDefined(method, McpDirection.serverToClient, revision,
            extensions: _extensionsInUse);
    if (handler == null || defined == false) {
      return _errorMessage(id,
          code: McpProtocol.errorMethodNotFound, message: 'Method not found: $method');
    }
    final params = request.params ?? const <String, dynamic>{};
    final refusal = _incomingRefusal(method, params);
    if (refusal != null) {
      return _errorMessage(id, code: refusal.$1, message: refusal.$2);
    }
    // 2025-11-25: a task-augmented request this client accepts as a task.
    if (params['task'] is Map && _acceptsTaskFor(method)) {
      return _startClientTask(id, method, handler, params);
    }
    _incomingCancelled[id] = false;
    final meta = params['_meta'];
    final progressToken = meta is Map ? meta['progressToken'] : null;
    if (progressToken is String || progressToken is int) _incomingProgress[progressToken] = null;
    try {
      final result = await handler(params);
      if (_incomingCancelled[id] == true) return null;
      if (method == 'elicitation/create') {
        final problem = _elicitationAnswerProblem(params, result);
        if (problem != null) {
          return _errorMessage(id, code: McpProtocol.errorInternal, message: problem);
        }
      }
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on McpUserRejected catch (e) {
      if (_incomingCancelled[id] == true) return null;
      // Sampling error handling: the user declined.
      return _errorMessage(id, code: -1, message: e.message);
    } on McpError catch (e) {
      if (_incomingCancelled[id] == true) return null;
      return _errorMessage(id, code: e.code ?? McpProtocol.errorInternal, message: e.message, data: e.data);
    } catch (e) {
      if (_incomingCancelled[id] == true) return null;
      return _errorMessage(id, code: McpProtocol.errorInternal, message: 'Handler error: $e');
    } finally {
      _incomingCancelled.remove(id);
      _incomingProgress.remove(progressToken);
    }
  }

  /// Why this client refuses a server request it has a handler for: a
  /// capability it did not declare, or a request breaking the rules.
  (int, String)? _incomingRefusal(String method, Map<String, dynamic> params) {
    final caps = capabilities;
    switch (method) {
      case 'sampling/createMessage':
        if (!caps.samplingDeclared) return (McpProtocol.errorMethodNotFound, 'Sampling is not supported');
        if ((params['tools'] != null || params['toolChoice'] != null) && !caps.samplingTools) {
          return (McpProtocol.errorInvalidParams, 'Tool use in sampling is not supported (no sampling.tools)');
        }
        final context = params['includeContext'];
        if ((context == 'thisServer' || context == 'allServers') && !caps.samplingContext) {
          return (McpProtocol.errorInvalidParams, 'includeContext is not supported (no sampling.context)');
        }
        final problem = samplingMessagesProblem(params['messages']);
        if (problem != null) return (McpProtocol.errorInvalidParams, problem);
      case 'roots/list':
        if (!caps.rootsDeclared) return (McpProtocol.errorMethodNotFound, 'Roots are not supported');
      case 'elicitation/create':
        if (!caps.elicitationDeclared) {
          return (McpProtocol.errorMethodNotFound, 'Elicitation is not supported');
        }
        // A request without a mode is form mode; an elicitation capability
        // naming no mode supports form.
        final mode = params['mode'] ?? 'form';
        final form = caps.elicitationForm || !caps.elicitationUrl;
        if (mode == 'url' && !caps.elicitationUrl) {
          return (McpProtocol.errorInvalidParams, 'URL mode elicitation is not supported');
        }
        if (mode == 'form' && !form) {
          return (McpProtocol.errorInvalidParams, 'Form mode elicitation is not supported');
        }
        if (mode != 'url' && mode != 'form') {
          return (McpProtocol.errorInvalidParams, 'Unknown elicitation mode: $mode');
        }
        final problem = elicitationRequestProblem(params);
        if (problem != null) return (McpProtocol.errorInvalidParams, problem);
    }
    return null;
  }

  /// Checks this client's own answer to an elicitation: accepted form
  /// content must match the requested schema (clients should validate
  /// responses). URL-mode ids are remembered for completion notices.
  String? _elicitationAnswerProblem(Map<String, dynamic> params, Map<String, dynamic> result) {
    if ((params['mode'] ?? 'form') == 'url') {
      if (result['action'] == 'accept') _pendingUrlElicitations.add(params['elicitationId'] as String);
      return null;
    }
    if (result['action'] != 'accept') return null;
    final check = JsonSchemaValidator(params['requestedSchema'], assertFormat: true)
        .validate(result['content'] ?? const <String, dynamic>{});
    return check.valid ? null : 'Elicitation content does not match requestedSchema: ${check.errors.join('; ')}';
  }

  /// URL-mode elicitations this client knows are open.
  final Set<String> _pendingUrlElicitations = {};

  final StreamController<String> _elicitationCompleteController = StreamController<String>.broadcast();

  /// `elicitationId`s the server reports complete
  /// (`notifications/elicitation/complete`), for URL-mode elicitations this
  /// client accepted or received in a URL-elicitation-required error. Ids it
  /// does not know, or already saw complete, are ignored.
  Stream<String> get onElicitationComplete => _elicitationCompleteController.stream;

  static Map<String, dynamic> _errorMessage(Object? id,
          {required int code, required String message, Object? data}) =>
      {
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      };

  /// Handle a JSON-RPC response
  void _handleResponse(JsonRpcMessage response) {
    final id = response.id;
    // 2026-07-28 (SEP-2577): the terminal `SubscriptionsListenResult` (id ==
    // subscriptionId) closes the subscription stream gracefully.
    if (id is int && _subscriptions.containsKey(id)) {
      final sub = _subscriptions.remove(id)!;
      if (!sub.ackCompleter.isCompleted) {
        sub.ackCompleter.complete(SubscriptionFilter());
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
      final error = McpError(message, code: code, data: response.error!['data']);
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
    if (method != null) _invalidateCache(method, params);

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
              : SubscriptionFilter());
        }
        return;
      }
      if (method != null && !sub.controller.isClosed) {
        sub.controller.add(SubscriptionNotification(
          method: method,
          params: Map<String, dynamic>.from(params),
        ));
      }
      if (!sub.forwardToHandlers) return;
    }

    if (method == 'notifications/elicitation/complete') {
      final elicitationId = params['elicitationId'];
      if (elicitationId is String && _pendingUrlElicitations.remove(elicitationId)) {
        _elicitationCompleteController.add(elicitationId);
      }
    }

    // The server cancelled one of its requests to this client.
    if (method == 'notifications/cancelled') {
      final requestId = params['requestId'];
      if (requestId != null && _incomingCancelled.containsKey(requestId)) {
        _incomingCancelled[requestId] = true;
      }
    }

    // Progress for a request this client is waiting on.
    if (method == McpProtocol.methodProgress) {
      final listener = _progressListeners[params['progressToken']];
      if (listener != null) {
        listener(ProgressNotificationParams.fromJson(Map<String, Object?>.from(params)));
      }
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
    Map<String, dynamic> params, [
    RequestOptions? options,
    bool reissued = false,
  ]) async {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    // A protocol method the revision in use does not define is not sent.
    final revision = _statelessMode ? McpProtocol.v2026_07_28 : _negotiatedProtocolVersion;
    if (revision != null &&
        method != 'initialize' &&
        mcpMethodDefined(method, McpDirection.clientToServer, revision,
                extensions: _extensionsInUse) ==
            false) {
      throw McpError('$method is not part of protocol $revision',
          code: McpProtocol.errorMethodNotFound);
    }

    final cacheKey = _cacheKey(method, params);
    if (cacheKey != null) {
      final hit = _resultCache[cacheKey];
      if (hit != null && DateTime.now().isBefore(hit.freshUntil)) return hit.result;
      _resultCache.remove(cacheKey);
    }

    final id = _requestId++;
    final completer = Completer<dynamic>();
    _requestCompleters[id] = completer;

    // Create a deep copy of params to avoid potential modification issues
    final Map<String, dynamic> safeParams = Map<String, dynamic>.from(params);

    // Progress (basic utilities): a token of this client's own in `_meta`
    // routes the server's `notifications/progress` for this request back to
    // [RequestOptions.onProgress].
    final onProgress = options?.onProgress;
    final progressToken = onProgress == null ? null : 'progress-$id';
    if (progressToken != null) {
      final meta = safeParams['_meta'] is Map
          ? Map<String, dynamic>.from(safeParams['_meta'] as Map)
          : <String, dynamic>{};
      meta['progressToken'] = progressToken;
      safeParams['_meta'] = meta;
    }

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
      // Transport-internal: Mcp-Param-* headers mirroring tool arguments.
      if (method == 'tools/call' && _mirrorsParamHeaders)
        StreamableHttpClientTransport.extraHeadersKey: mcpParamHeaderValues(
            _toolParamHeaders[safeParams['name']] ?? const [],
            safeParams['arguments'] is Map ? safeParams['arguments'] as Map : const {}),
    };

    try {
      _transport!.send(request);
    } catch (e) {
      _requestCompleters.remove(id);
      final error = McpError('Failed to send request: $e');
      _errorStreamController.add(error);
      throw error;
    }

    // Lifecycle, timeouts: wait [RequestOptions.timeout] (or
    // [requestTimeout]); progress restarts the wait, never past
    // [maxRequestTimeout]; on expiry tell the server with
    // `notifications/cancelled` and stop waiting.
    final perRequest = options?.timeout ?? requestTimeout;
    final started = DateTime.now();
    Timer? timer;
    void expire() {
      if (completer.isCompleted) return;
      _requestCompleters.remove(id);
      if (method != 'initialize') _cancelOnWire(id, 'Request timed out: $method');
      final error = McpError('Request timed out: $method');
      _errorStreamController.add(error);
      completer.completeError(error);
    }

    void arm(Duration d) {
      timer?.cancel();
      timer = Timer(d, expire);
    }

    arm(perRequest < maxRequestTimeout ? perRequest : maxRequestTimeout);
    // Cancellation by the caller. `initialize` is never cancelled.
    options?.cancel?.then((reason) {
      if (completer.isCompleted || method == 'initialize') return;
      _requestCompleters.remove(id);
      _cancelOnWire(id, reason is String ? reason : null);
      completer.completeError(McpError('Request cancelled: $method'));
    });
    if (progressToken != null) {
      _progressListeners[progressToken] = (progress) {
        final remaining = maxRequestTimeout - DateTime.now().difference(started);
        if (remaining > Duration.zero) {
          arm(remaining < perRequest ? remaining : perRequest);
        }
        onProgress!(progress);
      };
    }

    try {
      final result = await completer.future;
      if (cacheKey != null && result is Map) _remember(cacheKey, result);
      if (_statelessMode && result is Map) {
        // 2026-07-28: a resultType this client does not know makes the
        // result invalid; an absent one means "complete".
        final type = result[McpResultType.key];
        if (type != null && !_knownResultTypes.contains(type)) {
          throw McpError('Invalid result for $method: unknown resultType "$type"',
              code: McpProtocol.errorInvalidRequest);
        }
        // A task is a valid answer only to a request that supports tasks,
        // from a client that declared the extension.
        if (type == McpResultType.task &&
            (method != 'tools/call' || !capabilities.hasExtension(tasksExtensionId))) {
          throw McpError('Invalid result for $method: a task was not expected',
              code: McpProtocol.errorInvalidRequest);
        }
      }
      return result;
    } on McpError catch (e) {
      // Streamable HTTP: the server ended the session (404). Start a new
      // one with initialize and send the request again, once.
      if (e.code == McpProtocol.errorSessionExpired &&
          !_statelessMode &&
          method != 'initialize' &&
          !_renewingSession) {
        _renewingSession = true;
        try {
          _initialized = false;
          await initialize();
        } finally {
          _renewingSession = false;
        }
        return _sendRequest(method, params, options);
      }
      // 2026-07-28: a broken response stream loses the request; it is sent
      // again as a new request (new id), once.
      if (e.code == McpProtocol.errorNetwork && _statelessMode && !reissued) {
        return _sendRequest(method, params, options, true);
      }
      if (e.code == McpProtocol.errorAuthenticationRequired) _resultCache.clear();
      // URL elicitation required: its elicitations may later be completed.
      if (e.code == McpProtocol.errorUrlElicitationRequired && e.data is Map) {
        final list = (e.data as Map)['elicitations'];
        if (list is List) {
          for (final x in list) {
            if (x is Map && x['elicitationId'] is String) _pendingUrlElicitations.add(x['elicitationId'] as String);
          }
        }
      }
      // A cursor the server no longer accepts: every cached page is suspect.
      if (e.code == McpProtocol.errorInvalidParams && params.containsKey('cursor')) {
        _resultCache.removeWhere((key, _) => key.startsWith('$method '));
      }
      // 2026-07-28: no mutually supported version — say which the server has.
      if (e.code == McpProtocol.errorUnsupportedProtocolVersion) {
        final error = McpError(
          'Unsupported protocol version for $method: the server supports '
          '${_supportedFrom(e).join(", ")}',
          code: e.code,
          data: e.data,
        );
        throw error;
      }
      rethrow;
    } catch (e) {
      if (e is! McpError) {
        final error = McpError('Request failed: $e');
        _errorStreamController.add(error);
        throw error;
      }
      rethrow;
    } finally {
      timer?.cancel();
      if (progressToken != null) _progressListeners.remove(progressToken);
    }
  }

  /// Caching (2026-07-28): keep cacheable results while their `ttlMs` says
  /// they are fresh. Off by default. One client is one authorization
  /// context; call [clearResultCache] when its credentials change (an
  /// authentication-required error clears it too).
  bool cacheResults = false;

  final Map<String, _CachedResult> _resultCache = {};

  /// Drop every cached result.
  void clearResultCache() => _resultCache.clear();

  static const Set<String> _cacheableMethods = {
    'server/discover', 'tools/list', 'prompts/list', 'resources/list',
    'resources/templates/list', 'resources/read',
  };

  /// The cache key: the method and every parameter the caller sent. Results
  /// of multi-round-trip retries are never cached.
  String? _cacheKey(String method, Map<String, dynamic> params) {
    if (!cacheResults || !_statelessMode || !_cacheableMethods.contains(method)) return null;
    if (params.containsKey('inputResponses') || params.containsKey('requestState')) return null;
    return '$method ${jsonEncode(params)}';
  }

  void _remember(String key, Map result) {
    if (result[McpResultType.key] == McpResultType.inputRequired) return;
    final ttl = result['ttlMs'];
    // Absent or non-positive: immediately stale, nothing to keep.
    if (ttl is! int || ttl <= 0) return;
    _resultCache[key] = _CachedResult(result, DateTime.now().add(Duration(milliseconds: ttl)));
  }

  /// A notification that says cached results are out of date.
  void _invalidateCache(String method, Map<String, dynamic> params) {
    if (_resultCache.isEmpty) return;
    bool stale(String key) => switch (method) {
          'notifications/tools/list_changed' => key.startsWith('tools/list '),
          'notifications/prompts/list_changed' => key.startsWith('prompts/list '),
          'notifications/resources/list_changed' =>
            key.startsWith('resources/list ') || key.startsWith('resources/templates/list '),
          'notifications/resources/updated' => key.startsWith('resources/read '),
          _ => false,
        };
    _resultCache.removeWhere((key, _) => stale(key));
  }

  bool _renewingSession = false;

  static const Set<String> _knownResultTypes = {
    McpResultType.complete,
    McpResultType.inputRequired,
    McpResultType.task,
  };

  /// Build the stateless-path `_meta` (reverse-DNS client info + per-request
  /// capabilities + protocol version), preserving any [existingMeta].
  Map<String, dynamic> _statelessMeta(Object? existingMeta) => McpRequestMeta.build(
        protocolVersion: McpProtocol.v2026_07_28,
        clientCapabilities: capabilities.toJson(),
        clientInfo: _clientInfo,
        logLevel: _logLevel?.name,
        extra:
            existingMeta is Map ? Map<String, dynamic>.from(existingMeta) : null,
      );

  /// Attach a caller-supplied request `_meta` to [params]. [meta] is the
  /// application's own context (e.g. a forwarding host relaying its caller);
  /// use namespaced keys (`prefix/name`). On the stateless path the reserved
  /// `io.modelcontextprotocol/*` keys are written after it and always win.
  static Map<String, dynamic> _withMeta(
    Map<String, dynamic> params,
    Map<String, dynamic>? meta,
  ) {
    if (meta == null || meta.isEmpty) return params;
    return <String, dynamic>{
      ...params,
      '_meta': Map<String, dynamic>.from(meta),
    };
  }

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
      String method, Map<String, dynamic> params, [RequestOptions? options]) async {
    var currentParams = params;
    for (var round = 0; round < _mrtrMaxRounds; round++) {
      final raw = await _sendRequest(method, currentParams, options);
      final result = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      if (!_statelessMode ||
          McpResultType.of(result) != McpResultType.inputRequired) {
        return result;
      }
      final required = InputRequiredResult.fromJson(result);
      final inputResponses = <String, dynamic>{};
      final rawRequests = result['inputRequests'];
      for (final entry in (rawRequests is Map ? rawRequests : const {}).entries) {
        final req = entry.value is Map ? Map<String, dynamic>.from(entry.value as Map) : const <String, dynamic>{};
        final reqMethod = req['method'] as String?;
        if (reqMethod == null) {
          throw McpError('InputRequest `${entry.key}` is missing a method');
        }
        final reqParams = req['params'] is Map
            ? Map<String, dynamic>.from(req['params'] as Map)
            : <String, dynamic>{};
        inputResponses[entry.key] = await _fulfilInput(reqMethod, reqParams);
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

  /// Answer one server input request (multi round-trip or task input) the
  /// way a direct request would be answered: refused when undeclared or
  /// malformed, the handler's answer checked.
  Future<Map<String, dynamic>> _fulfilInput(String method, Map<String, dynamic> params) async {
    final handler = _requestHandlers[method];
    if (handler == null) throw McpError('No handler registered for server input request `$method`');
    final refusal = _incomingRefusal(method, params);
    if (refusal != null) throw McpError(refusal.$2, code: refusal.$1);
    final result = await handler(params);
    if (method == 'elicitation/create') {
      final problem = _elicitationAnswerProblem(params, result);
      if (problem != null) throw McpError(problem, code: McpProtocol.errorInternal);
    }
    return result;
  }

  /// Open a 2026-07-28 `subscriptions/listen` stream (SEP-2577) — the stateless
  /// replacement for the `resources/subscribe` RPC + the HTTP GET SSE stream.
  ///
  /// Sends the request with the opt-in [filter]; the returned [Subscription]
  /// exposes the server's acknowledged (honored) filter, the stream of stamped
  /// notifications, and `cancel()` (which terminates the stream via
  /// `notifications/cancelled`). Stateless mode only.
  Future<Subscription> listen(SubscriptionFilter filter) => _listen(filter);

  Future<Subscription> _listen(SubscriptionFilter filter, {bool forwardToHandlers = false}) async {
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
      forwardToHandlers: forwardToHandlers,
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
        final sub = _subscriptions.remove(id);
        if (sub != null) {
          _cancelOnWire(id, null);
          if (!sub.controller.isClosed) sub.controller.close();
        }
      },
    );
  }

  /// Send a JSON-RPC notification
  void _sendNotification(String method, Map<String, dynamic> params) {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final revision = _statelessMode ? McpProtocol.v2026_07_28 : _negotiatedProtocolVersion;
    if (revision != null &&
        mcpMethodDefined(method, McpDirection.clientToServer, revision, extensions: _extensionsInUse) == false) {
      throw McpError('$method is not part of protocol $revision', code: McpProtocol.errorMethodNotFound);
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

  /// The stream behind [Client.subscribeResource] on 2026-07-28: its
  /// notifications go to the client's ordinary handlers.
  final bool forwardToHandlers;

  _ClientSubscription({
    required this.id,
    required this.ackCompleter,
    required this.controller,
    this.forwardToHandlers = false,
  });
}

/// What a `server/discover` result means to this client.
extension DiscoverResultAccess on DiscoverResult {
  /// The capabilities as this package's [ServerCapabilities].
  ServerCapabilities get serverCapabilities => ServerCapabilities.fromJson(
        Map<String, dynamic>.from(this['capabilities'] as Map? ?? const {}),
      );

  /// Self-reported server identity from the result `_meta`
  /// (`io.modelcontextprotocol/serverInfo`), if present.
  Map<String, dynamic>? get serverInfo => McpRequestMeta.readServerInfo(this['_meta']);
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

  /// A keep-alive ping went unanswered
  pingTimeout,

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

/// Per-request settings.
class RequestOptions {
  const RequestOptions({this.timeout, this.onProgress, this.cancel});

  /// How long to wait for the response (default [Client.requestTimeout]).
  final Duration? timeout;

  /// Receives the server's `notifications/progress` for this request. Setting
  /// it sends a `progressToken`, which is how a server knows to report
  /// progress; each notification also restarts the timeout (bounded by
  /// [Client.maxRequestTimeout]).
  final void Function(ProgressNotificationParams progress)? onProgress;

  /// Completing this cancels the request: the server is sent
  /// `notifications/cancelled` (with the value as the reason when it is a
  /// string) and the call fails with an [McpError]. A response that arrives
  /// afterwards is ignored.
  final Future<Object?>? cancel;
}

/// Which protocol era a connection speaks (specification, versioning).
enum ProtocolEra {
  /// Probe with `server/discover`: modern when the server answers in the
  /// modern era, otherwise the `initialize` handshake.
  auto,

  /// Per-request `_meta`, no handshake (2026-07-28).
  modern,

  /// The `initialize` handshake (2025-11-25 and earlier).
  legacy,
}

class _CachedResult {
  _CachedResult(this.result, this.freshUntil);
  final Map result;
  final DateTime freshUntil;
}

/// Thrown by a sampling handler when the user declines the request; the
/// server receives error code -1 (client/sampling: error handling).
class McpUserRejected implements Exception {
  const McpUserRejected([this.message = 'User rejected sampling request']);
  final String message;

  @override
  String toString() => 'McpUserRejected: $message';
}
