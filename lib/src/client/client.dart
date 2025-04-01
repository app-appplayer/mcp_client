import 'dart:async';
import 'dart:convert';

import '../../logger.dart';
import '../models/models.dart';
import '../transport/transport.dart';

final Logger _logger = Logger.getLogger('mcp_client.client');

/// Main MCP Client class that handles all client-side protocol operations
class Client {
  /// Name of the MCP client
  final String name;

  /// Version of the MCP client implementation
  final String version;

  /// Client capabilities configuration
  final ClientCapabilities capabilities;

  /// Protocol version this client implements
  final String protocolVersion = "2024-11-05";

  /// Transport connection
  ClientTransport? _transport;

  /// Stream controller for handling incoming messages
  final _messageController = StreamController<JsonRpcMessage>.broadcast();

  /// Request identifier counter
  int _requestId = 1;

  /// Map of request completion handlers by ID
  final _requestCompleters = <int, Completer<dynamic>>{};

  /// Map of notification handlers by method
  final _notificationHandlers = <String, Function(Map<String, dynamic>)>{};

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

  /// Get the server capabilities
  ServerCapabilities? get serverCapabilities => _serverCapabilities;

  /// Get the server information
  Map<String, dynamic>? get serverInfo => _serverInfo;

  /// Creates a new MCP client with the specified parameters
  Client({
    required this.name,
    required this.version,
    this.capabilities = const ClientCapabilities(),
  });

  /// Connect the client to a transport
  Future<void> connect(ClientTransport transport) async {
    if (_transport != null) {
      throw McpError('Client is already connected to a transport');
    }

    if (_connecting) {
      throw McpError('Client is already connecting to a transport');
    }

    _connecting = true;
    _transport = transport;
    _transport!.onMessage.listen(_handleMessage);
    _transport!.onClose.then((_) {
      _onDisconnect();
    });

    // Set up message handling
    _messageController.stream.listen((message) async {
      try {
        await _processMessage(message);
      } catch (e) {
        _logger.debug('Error processing message: $e');
      }
    });

    // Initialize the connection
    try {
      await initialize();
      _connecting = false;
    } catch (e) {
      _connecting = false;
      disconnect();
      rethrow;
    }
  }

  Future<void> connectWithRetry(
      ClientTransport transport, {
        int maxRetries = 3,
        Duration delay = const Duration(seconds: 2)
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
        _transport!.onClose.then((_) {
          _onDisconnect();
        });

        // Message handling setup
        _messageController.stream.listen((message) async {
          try {
            await _processMessage(message);
          } catch (e) {
            _logger.debug('Error processing message: $e');
          }
        });

        // Initialize connection
        await initialize();
        _connecting = false;
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
          throw McpError('Failed to connect after $maxRetries attempts: $e');
        }

        _logger.debug('Connection attempt $attempts failed: $e. Retrying in ${delay.inSeconds} seconds...');
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
      'clientInfo': {
        'name': name,
        'version': version,
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
    _serverCapabilities = ServerCapabilities.fromJson(response['capabilities'] ?? {});

    // Send initialized notification
    _sendNotification('initialized', {});

    _initialized = true;
    _logger.debug('Initialization complete');
  }

  /// Validate protocol version compatibility
  void _validateProtocolVersion(String serverProtoVersion) {
    _logger.warning('Protocol version mismatch: Client=$protocolVersion, Server=$serverProtoVersion');

    // Check if server protocol version is at least compatible
    try {
      final clientDate = DateTime.parse(protocolVersion);
      final serverDate = DateTime.parse(serverProtoVersion);

      if (serverDate.isBefore(clientDate)) {
        _logger.warning('Server protocol version ($serverProtoVersion) is older than client protocol version ($protocolVersion)');
      }
    } catch (e) {
      // Date parsing failed, fallback to string comparison
      _logger.warning('Unable to parse protocol versions as dates for comparison');
    }
  }

  /// List available tools on the server
  Future<List<Tool>> listTools() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    final response = await _sendRequest('tools/list', {});
    final toolsList = response['tools'] as List<dynamic>;
    return toolsList.map((tool) => Tool.fromJson(tool)).toList();
  }

  /// Call a tool on the server
  Future<CallToolResult> callTool(String name, Map<String, dynamic> toolArguments) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.tools != true) {
      throw McpError('Server does not support tools');
    }

    // Create a clean params map with properly typed values
    final Map<String, dynamic> params = {
      'name': name,
      'arguments': Map<String, dynamic>.from(toolArguments),
    };

    final response = await _sendRequest('tools/call', params);
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
      Map<String, dynamic> arguments,
      {bool trackProgress = true}
      ) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.tools != true) {
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

    return ToolCallTracking(
      operationId: operationId,
      result: result,
    );
  }

  /// Cancel an operation that is in progress on the server
  ///
  /// [operationId] - The ID of the operation to cancel
  ///
  /// Returns a Future that completes when the cancellation request is processed
  Future<void> cancelOperation(String operationId) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    await _sendRequest('cancel', {
      'id': operationId,
    });
  }

  /// List available resources on the server
  Future<List<Resource>> listResources() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest('resources/list', {});
    final resourcesList = response['resources'] as List<dynamic>;
    return resourcesList.map((resource) => Resource.fromJson(resource)).toList();
  }

  /// Read a resource from the server
  Future<ReadResourceResult> readResource(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest('resources/read', {
      'uri': uri,
    });

    return ReadResourceResult.fromJson(response);
  }

  /// Get a resource using a template
  ///
  /// [templateUri] - The URI template to use
  /// [params] - Parameters to fill in the template
  ///
  /// Returns a Future that resolves to the resource content
  Future<ReadResourceResult> getResourceWithTemplate(String templateUri, Map<String, dynamic> params) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.resources != true) {
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

    if (_serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    await _sendRequest('resources/subscribe', {
      'uri': uri,
    });
  }

  /// Unsubscribe from a resource
  Future<void> unsubscribeResource(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    await _sendRequest('resources/unsubscribe', {
      'uri': uri,
    });
  }

  /// List resource templates on the server
  Future<List<ResourceTemplate>> listResourceTemplates() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.resources != true) {
      throw McpError('Server does not support resources');
    }

    final response = await _sendRequest('resources/templates/list', {});
    final templatesList = response['resourceTemplates'] as List<dynamic>;
    return templatesList.map((template) => ResourceTemplate.fromJson(template)).toList();
  }

  /// List available prompts on the server
  Future<List<Prompt>> listPrompts() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.prompts != true) {
      throw McpError('Server does not support prompts');
    }

    final response = await _sendRequest('prompts/list', {});
    final promptsList = response['prompts'] as List<dynamic>;
    return promptsList.map((prompt) => Prompt.fromJson(prompt)).toList();
  }

  /// Get a prompt from the server
  Future<GetPromptResult> getPrompt(String name, [Map<String, dynamic>? promptArguments]) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.prompts != true) {
      throw McpError('Server does not support prompts');
    }

    // Create a new map to hold params to avoid direct modification
    final Map<String, dynamic> params = {
      'name': name,
    };

    // Only add arguments if provided, and ensure it's a proper Map<String, dynamic>
    if (promptArguments != null) {
      params['arguments'] = Map<String, dynamic>.from(promptArguments);
    }

    final response = await _sendRequest('prompts/get', params);
    return GetPromptResult.fromJson(response);
  }

  /// Request model sampling from the server
  Future<CreateMessageResult> createMessage(CreateMessageRequest request) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (_serverCapabilities?.sampling != true) {
      throw McpError('Server does not support sampling');
    }

    final response = await _sendRequest('sampling/createMessage', request.toJson());
    return CreateMessageResult.fromJson(response);
  }

  /// Request the current health status of the server
  ///
  /// Returns a Map containing server health metrics including:
  /// - is_running: Whether the server is running
  /// - connected_sessions: Number of connected sessions
  /// - registered_tools: Number of registered tools
  /// - registered_resources: Number of registered resources
  /// - registered_prompts: Number of registered prompts
  /// - start_time: When the server started
  /// - uptime_seconds: How long the server has been running
  /// - metrics: Detailed performance metrics
  Future<ServerHealth> healthCheck() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    final response = await _sendRequest('health/check', {});
    return ServerHealth.fromJson(response);
  }

  /// Add a root
  Future<void> addRoot(Root root) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!capabilities.roots) {
      throw McpError('Client does not support roots');
    }

    await _sendRequest('roots/add', {
      'root': root.toJson(),
    });

    if (capabilities.rootsListChanged) {
      _sendNotification('notifications/roots/list_changed', {});
    }
  }

  /// Remove a root
  Future<void> removeRoot(String uri) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!capabilities.roots) {
      throw McpError('Client does not support roots');
    }

    await _sendRequest('roots/remove', {
      'uri': uri,
    });

    if (capabilities.rootsListChanged) {
      _sendNotification('notifications/roots/list_changed', {});
    }
  }

  /// List roots
  Future<List<Root>> listRoots() async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    if (!capabilities.roots) {
      throw McpError('Client does not support roots');
    }

    final response = await _sendRequest('roots/list', {});
    final rootsList = response['roots'] as List<dynamic>;
    return rootsList.map((root) => Root.fromJson(root)).toList();
  }

  /// Set the logging level for the server
  Future<void> setLoggingLevel(McpLogLevel level) async {
    if (!_initialized) {
      throw McpError('Client is not initialized');
    }

    await _sendRequest('logging/set_level', {
      'level': level.index,
    });
  }

  /// Register a notification handler
  void onNotification(String method, Function(Map<String, dynamic>) handler) {
    _notificationHandlers[method] = handler;
  }

  /// Handle tools list changed notification
  void onToolsListChanged(Function() handler) {
    onNotification('notifications/tools/list_changed', (_) => handler());
  }

  /// Handle resources list changed notification
  void onResourcesListChanged(Function() handler) {
    onNotification('notifications/resources/list_changed', (_) => handler());
  }

  /// Handle prompts list changed notification
  void onPromptsListChanged(Function() handler) {
    onNotification('notifications/prompts/list_changed', (_) => handler());
  }

  /// Handle roots list changed notification
  void onRootsListChanged(Function() handler) {
    onNotification('notifications/roots/list_changed', (_) => handler());
  }

  /// Handle resource updated notification
  void onResourceUpdated(Function(String) handler) {
    onNotification('notifications/resources/updated', (params) {
      final uri = params['uri'] as String;
      handler(uri);
    });
  }

  /// Register a handler for resource update notifications with content
  ///
  /// The handler will be called with:
  /// [uri] - The URI of the updated resource
  /// [content] - The new content of the resource
  void onResourceContentUpdated(Function(String uri, ResourceContentInfo content) handler) {
    onNotification('notifications/resources/updated', (params) {
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
  void onProgress(Function(String requestId, double progress, String message) handler) {
    onNotification('progress', (params) {
      final requestId = params['requestId'] as String? ?? params['request_id'] as String;
      final progress = params['progress'] as double;
      final message = params['message'] as String;
      handler(requestId, progress, message);
    });
  }

  /// Register a handler for sampling response notifications
  ///
  /// The handler will be called with:
  /// [requestId] - The ID of the sampling request
  /// [result] - The sampling result from the LLM
  void onSamplingResponse(Function(String requestId, CreateMessageResult result) handler) {
    onNotification('sampling/response', (params) {
      final requestId = params['requestId'] as String? ?? params['request_id'] as String;
      final resultData = params['result'] as Map<String, dynamic>;
      final result = CreateMessageResult.fromJson(resultData);
      handler(requestId, result);
    });
  }

  /// Handle logging notification
  void onLogging(Function(McpLogLevel, String, String?, Map<String, dynamic>?) handler) {
    onNotification('logging', (params) {
      final level = McpLogLevel.values[params['level'] as int];
      final message = params['message'] as String;
      final logger = params['logger'] as String?;
      final data = params['data'] as Map<String, dynamic>?;
      handler(level, message, logger, data);
    });
  }

  /// Disconnect the client from its transport
  void disconnect() {
    if (_transport != null) {
      _transport!.close();
      _onDisconnect();
    }
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
    }
  }

  /// Process a JSON-RPC message
  Future<void> _processMessage(JsonRpcMessage message) async {
    if (message.isResponse) {
      _handleResponse(message);
    } else if (message.isNotification) {
      _handleNotification(message);
    } else {
      _logger.debug('Ignoring unexpected message type: ${message.toJson()}');
    }
  }

  /// Handle a JSON-RPC response
  void _handleResponse(JsonRpcMessage response) {
    final id = response.id;
    if (id == null || id is! int || !_requestCompleters.containsKey(id)) {
      _logger.debug('Received response with unknown id: $id');
      return;
    }

    final completer = _requestCompleters.remove(id)!;

    if (response.error != null) {
      final code = response.error!['code'] as int;
      final message = response.error!['message'] as String;
      completer.completeError(McpError(message, code: code));
    } else {
      completer.complete(response.result);
    }
  }

  /// Handle a JSON-RPC notification
  void _handleNotification(JsonRpcMessage notification) {
    final method = notification.method;
    final params = notification.params ?? {};

    final handler = _notificationHandlers[method];
    if (handler != null) {
      try {
        handler(params);
      } catch (e) {
        _logger.debug('Error in notification handler: $e');
      }
    } else {
      _logger.debug('No handler for notification: $method');
    }
  }

  /// Send a JSON-RPC request
  Future<dynamic> _sendRequest(String method, Map<String, dynamic> params) async {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final id = _requestId++;
    final completer = Completer<dynamic>();
    _requestCompleters[id] = completer;

    // Create a deep copy of params to avoid potential modification issues
    final Map<String, dynamic> safeParams = Map<String, dynamic>.from(params);

    final request = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': safeParams,
    };

    try {
      _transport!.send(request);
    } catch (e) {
      _requestCompleters.remove(id);
      throw McpError('Failed to send request: $e');
    }

    try {
      // Add timeout for requests
      final result = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _requestCompleters.remove(id);
          throw McpError('Request timed out: $method');
        },
      );
      return result;
    } catch (e) {
      if (e is! McpError) {
        throw McpError('Request failed: $e');
      }
      rethrow;
    }
  }

  /// Send a JSON-RPC notification
  void _sendNotification(String method, Map<String, dynamic> params) {
    if (!isConnected) {
      throw McpError('Client is not connected to a transport');
    }

    final notification = {
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    };

    _transport!.send(notification);
  }
}

/// Client capabilities configuration
class ClientCapabilities {
  /// Root management support
  final bool roots;

  /// Whether roots list changes are sent as notifications
  final bool rootsListChanged;

  /// Sampling support
  final bool sampling;

  /// Create a capabilities object with specified settings
  const ClientCapabilities({
    this.roots = false,
    this.rootsListChanged = false,
    this.sampling = false,
  });

  /// Convert capabilities to JSON
  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{};

    if (roots) {
      result['roots'] = {'listChanged': rootsListChanged};
    }

    if (sampling) {
      result['sampling'] = {};
    }

    return result;
  }
}

/// Server capabilities
class ServerCapabilities {
  /// Tool support
  final bool tools;

  /// Whether tools list changes are sent as notifications
  final bool toolsListChanged;

  /// Resource support
  final bool resources;

  /// Whether resources list changes are sent as notifications
  final bool resourcesListChanged;

  /// Prompt support
  final bool prompts;

  /// Whether prompts list changes are sent as notifications
  final bool promptsListChanged;

  /// Sampling support
  final bool sampling;

  /// Server capabilities from JSON
  factory ServerCapabilities.fromJson(Map<String, dynamic> json) {
    final toolsData = json['tools'] as Map<String, dynamic>?;
    final resourcesData = json['resources'] as Map<String, dynamic>?;
    final promptsData = json['prompts'] as Map<String, dynamic>?;
    final samplingData = json['sampling'] as Map<String, dynamic>?;

    return ServerCapabilities(
      tools: toolsData != null,
      toolsListChanged: toolsData?['listChanged'] == true,
      resources: resourcesData != null,
      resourcesListChanged: resourcesData?['listChanged'] == true,
      prompts: promptsData != null,
      promptsListChanged: promptsData?['listChanged'] == true,
      sampling: samplingData != null,
    );
  }

  /// Create server capabilities object
  const ServerCapabilities({
    this.tools = false,
    this.toolsListChanged = false,
    this.resources = false,
    this.resourcesListChanged = false,
    this.prompts = false,
    this.promptsListChanged = false,
    this.sampling = false,
  });
}

/// Class to hold result of a tracked tool call
class ToolCallTracking {
  /// Operation ID for tracking progress
  final String? operationId;

  /// Result of the tool call
  final CallToolResult result;

  ToolCallTracking({
    this.operationId,
    required this.result,
  });
}