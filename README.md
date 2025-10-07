# MCP Client

## 🙌 Support This Project

If you find this package useful, consider supporting ongoing development on PayPal.

[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif)](https://www.paypal.com/ncp/payment/F7G56QD9LSJ92)  
Support makemind via [PayPal](https://www.paypal.com/ncp/payment/F7G56QD9LSJ92)

---

### 🔗 MCP Dart Package Family

- [`mcp_server`](https://pub.dev/packages/mcp_server): Exposes tools, resources, and prompts to LLMs. Acts as the AI server.
- [`mcp_client`](https://pub.dev/packages/mcp_client): Connects Flutter/Dart apps to MCP servers. Acts as the client interface.
- [`mcp_llm`](https://pub.dev/packages/mcp_llm): Bridges LLMs (Claude, OpenAI, etc.) to MCP clients/servers. Acts as the LLM brain.
- [`flutter_mcp`](https://pub.dev/packages/flutter_mcp): Complete Flutter plugin for MCP integration with platform features.
- [`flutter_mcp_ui_core`](https://pub.dev/packages/flutter_mcp_ui_core): Core models, constants, and utilities for Flutter MCP UI system. 
- [`flutter_mcp_ui_runtime`](https://pub.dev/packages/flutter_mcp_ui_runtime): Comprehensive runtime for building dynamic, reactive UIs through JSON specifications.
- [`flutter_mcp_ui_generator`](https://pub.dev/packages/flutter_mcp_ui_generator): JSON generation toolkit for creating UI definitions with templates and fluent API. 
- [`mcp_flow_runtime`](https://pub.dev/packages/mcp_flow_runtime): Declarative runtime for hardware control and IoT orchestration using MCP Flow DSL.

---

A Dart plugin for implementing [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) clients. This plugin allows Flutter applications to connect with MCP servers and access data, functionality, and interaction patterns from Large Language Model (LLM) applications in a standardized way.

## Features

- **MCP Protocol 2025-03-26** - Latest protocol specification support
- **Unified Transport Configuration** - Simplified transport setup with sealed classes
- **Enhanced Error Handling** - Result types for robust error management
- **OAuth 2.1 Authentication** - Built-in OAuth support for secure connections
- **Multiple Transport Types**:
  - **STDIO** - Local process communication (native platforms only)
  - **SSE** - Server-Sent Events with authentication, compression, and heartbeat (web and native)
  - **HTTP** - Streamable HTTP/2 transport with full feature support (web and native)
- **Core MCP Primitives**:
  - **Resources** - Access server data with templates and subscriptions
  - **Tools** - Execute server functionality with progress tracking
  - **Prompts** - Reusable interaction templates
  - **Roots** - Filesystem boundary management
  - **Sampling** - LLM text generation requests
- **Advanced Features**:
  - **Progress Tracking** - Monitor long-running operations
  - **Operation Cancellation** - Cancel ongoing tasks
  - **Batch Processing** - JSON-RPC batch requests
  - **Connection Monitoring** - Health checks and connection state events
  - **Resource Subscriptions** - Real-time resource update notifications
  - **Session Management** - Automatic session validation and reconnection support
  - **State Persistence** - Smart localStorage management with server restart detection
- **Cross-platform support**: Android, iOS, web, Linux, Windows, macOS
  - **Web Platform**: SSE and StreamableHTTP transports fully supported; STDIO is native-only

## Protocol Version

This package implements the Model Context Protocol (MCP) specification version `2025-03-26`.

The protocol version is crucial for ensuring compatibility between MCP clients and servers. Each release of this package may support different protocol versions, so it's important to:

- Check the CHANGELOG.md for protocol version updates
- Ensure client and server protocol versions are compatible
- Stay updated with the latest MCP specification

### Version Compatibility

- Primary protocol version: 2025-03-26
- Backward compatibility: 2024-11-05
- Compatibility: Tested with latest MCP server implementations

For the most up-to-date information on protocol versions and compatibility, refer to the [Model Context Protocol specification](https://spec.modelcontextprotocol.io).

## Getting Started

### Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mcp_client: ^1.0.2
```

Or install via command line:

```bash
dart pub add mcp_client
```

### Basic Usage

```dart
import 'package:mcp_client/mcp_client.dart';

void main() async {
  // Create client configuration
  final config = McpClient.simpleConfig(
    name: 'Example Client',
    version: '1.0.0',
    enableDebugLogging: true,
  );

  // Create transport configuration
  final transportConfig = TransportConfig.stdio(
    command: 'npx',
    arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/path/to/allowed/directory'],
  );
  
  // Create and connect client
  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );
  
  final client = clientResult.fold(
    (c) => c,
    (error) => throw Exception('Failed to connect: $error'),
  );
  
  // List available tools on the server
  final tools = await client.listTools();
  print('Available tools: ${tools.map((t) => t.name).join(', ')}');
  
  // Call a tool
  final result = await client.callTool('calculator', {
    'operation': 'add',
    'a': 5,
    'b': 3,
  });
  print('Result: ${(result.content.first as TextContent).text}');
  
  // Disconnect when done
  client.disconnect();
}
```

## Core Concepts

### Client

The `Client` is your core interface to the MCP protocol. It handles connection management, protocol compliance, and message routing:

```dart
// Method 1: Using unified configuration
final config = McpClient.productionConfig(
  name: 'My App',
  version: '1.0.0',
  capabilities: ClientCapabilities(
    roots: true,
    rootsListChanged: true,
    sampling: true,
  ),
);

final clientResult = await McpClient.createAndConnect(
  config: config,
  transportConfig: transportConfig,
);

// Method 2: Manual client creation
final client = McpClient.createClient(config);
```
### Connection State Monitoring

Monitor the connection state with event streams:

```dart
// Listen for connection events
client.onConnect.listen((serverInfo) {
  _logger.info('Connected to ${serverInfo.name} v${serverInfo.version}');
  _logger.info('Protocol version: ${serverInfo.protocolVersion}');
  // Initialize your application after connection
});

// Listen for disconnection events
client.onDisconnect.listen((reason) {
  _logger.info('Disconnected: $reason');
  
  // Handle different disconnect reasons
  switch (reason) {
    case DisconnectReason.transportError:
      // Attempt reconnection
      break;
    case DisconnectReason.serverDisconnected:
      // Show notification to user
      break;
    case DisconnectReason.clientDisconnected:
      // Normal shutdown
      break;
  }
});

// Listen for error events
client.onError.listen((error) {
  _logger.error('Error: ${error.message}');
  // Log errors or show to user
});

// Clean up resources when done
client.dispose();
```

### Resources

Resources provide access to data from MCP servers. They're similar to GET endpoints in a REST API:

```dart
// List available resources
final resources = await client.listResources();
_logger.debug('Available resources: ${resources.map((r) => r.name).join(', ')}');

// Read a resource
final resourceResult = await client.readResource('file:///path/to/file.txt');
final content = resourceResult.contents.first;
_logger.debug('Resource content: ${content.text}');

// Get a resource using a template
final templateResult = await client.getResourceWithTemplate('file:///{path}', {
  'path': 'example.txt'
});
_logger.debug('Template result: ${templateResult.contents.first.text}');

// Subscribe to resource updates
await client.subscribeResource('file:///path/to/file.txt');
client.onResourceContentUpdated((uri, content) {
  _logger.debug('Resource updated: $uri');
  _logger.debug('New content: ${content.text}');
});

// Unsubscribe when no longer needed
await client.unsubscribeResource('file:///path/to/file.txt');
```

### Tools

Tools allow you to execute functionality exposed by MCP servers:

```dart
// List available tools
final tools = await client.listTools();
_logger.debug('Available tools: ${tools.map((t) => t.name).join(', ')}');

// Call a tool
final result = await client.callTool('search-web', {
  'query': 'Model Context Protocol',
  'maxResults': 5,
});

// Call a tool with progress tracking
final trackingResult = await client.callToolWithTracking('long-running-operation', {
  'parameter': 'value'
});
final operationId = trackingResult.operationId;

// Register progress handler
client.onProgress((requestId, progress, message) {
  _logger.debug('Operation $requestId: $progress% - $message');
});

// Process the result
final content = result.content.first;
if (content is TextContent) {
  _logger.debug('Search results: ${content.text}');
}

// Cancel an operation if needed
await client.cancelOperation(operationId);
```

### Prompts

Prompts are reusable templates provided by servers that help with common interactions:

```dart
// List available prompts
final prompts = await client.listPrompts();
_logger.debug('Available prompts: ${prompts.map((p) => p.name).join(', ')}');

// Get a prompt result
final promptResult = await client.getPrompt('analyze-code', {
  'code': 'function add(a, b) { return a + b; }',
  'language': 'javascript',
});

// Process the prompt messages
for (final message in promptResult.messages) {
  final content = message.content;
  if (content is TextContent) {
    _logger.debug('${message.role}: ${content.text}');
  }
}
```

### Roots

Roots allow you to manage filesystem boundaries:

```dart
// Add a root
await client.addRoot(Root(
  uri: 'file:///path/to/allowed/directory',
  name: 'Project Files',
  description: 'Files for the current project',
));

// List roots
final roots = await client.listRoots();
_logger.debug('Configured roots: ${roots.map((r) => r.name).join(', ')}');

// Remove a root
await client.removeRoot('file:///path/to/allowed/directory');

// Register for roots list changes
client.onRootsListChanged(() {
  _logger.debug('Roots list has changed');
  client.listRoots().then((roots) {
    _logger.debug('New roots: ${roots.map((r) => r.name).join(', ')}');
  });
});
```

### Sampling

Sampling allows you to request LLM text generation through the MCP protocol:

```dart
// Create a sampling request
final request = CreateMessageRequest(
  messages: [
    Message(
      role: 'user',
      content: TextContent(text: 'What is the Model Context Protocol?'),
    ),
  ],
  modelPreferences: ModelPreferences(
    hints: [
      ModelHint(name: 'claude-3-sonnet'),
      ModelHint(name: 'claude-3-opus'),
    ],
    intelligencePriority: 0.8,
    speedPriority: 0.4,
  ),
  maxTokens: 1000,
  temperature: 0.7,
);

// Request sampling
final result = await client.createMessage(request);

// Process the result
_logger.debug('Model used: ${result.model}');
_logger.debug('Response: ${(result.content as TextContent).text}');

// Register for sampling responses
client.onSamplingResponse((requestId, result) {
  _logger.debug('Sampling response for request $requestId:');
  _logger.debug('Model: ${result.model}');
  _logger.debug('Content: ${(result.content as TextContent).text}');
});
```

### Server Health

Monitor the health status of connected MCP servers:

```dart
// Get server health status
final health = await client.healthCheck();
_logger.debug('Server running: ${health.isRunning}');
_logger.debug('Connected sessions: ${health.connectedSessions}');
_logger.debug('Registered tools: ${health.registeredTools}');
_logger.debug('Uptime: ${health.uptime.inMinutes} minutes');
```

## Transport Layers

MCP Client supports multiple transport types with unified configuration. Each transport automatically supports advanced features like OAuth authentication, compression, and heartbeat monitoring.

### Standard I/O

For command-line tools and direct integrations:

```dart
// Method 1: Using createAndConnect
final config = McpClient.simpleConfig(name: 'STDIO Client', version: '1.0.0');
final transportConfig = TransportConfig.stdio(
  command: 'npx',
  arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/path/to/allowed/directory'],
  workingDirectory: '/path/to/working/directory',
  environment: {'ENV_VAR': 'value'},
);

final clientResult = await McpClient.createAndConnect(
  config: config,
  transportConfig: transportConfig,
);

// Method 2: Manual transport creation
final transportResult = await McpClient.createStdioTransport(
  command: 'npx',
  arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/path/to/allowed/directory'],
);
final transport = transportResult.fold((t) => t, (error) => throw error);
await client.connect(transport);
```

### Server-Sent Events (SSE)

For HTTP-based communication with enhanced features:

```dart
// Basic SSE transport
final transportConfig = TransportConfig.sse(
  serverUrl: 'http://localhost:8080/sse',
  headers: {'User-Agent': 'MCP-Client/1.0'},
);

// SSE with Bearer token authentication
final transportConfig = TransportConfig.sse(
  serverUrl: 'https://secure-api.example.com/sse',
  bearerToken: 'your-bearer-token',
  headers: {'User-Agent': 'MCP-Client/1.0'},
);

// SSE with OAuth authentication
final transportConfig = TransportConfig.sse(
  serverUrl: 'https://api.example.com/sse',
  oauthConfig: OAuthConfig(
    authorizationEndpoint: 'https://auth.example.com/authorize',
    tokenEndpoint: 'https://auth.example.com/token',
    clientId: 'your-client-id',
  ),
);

// SSE with compression
final transportConfig = TransportConfig.sse(
  serverUrl: 'http://localhost:8080/sse',
  enableCompression: true,
  enableGzip: true,
  enableDeflate: true,
);

// SSE with heartbeat monitoring
final transportConfig = TransportConfig.sse(
  serverUrl: 'http://localhost:8080/sse',
  heartbeatInterval: const Duration(seconds: 30),
  maxMissedHeartbeats: 3,
);

final clientResult = await McpClient.createAndConnect(
  config: config,
  transportConfig: transportConfig,
);
```

### Streamable HTTP Transport

For high-performance HTTP/2 communication:

```dart
// Basic HTTP transport
final transportConfig = TransportConfig.streamableHttp(
  baseUrl: 'https://api.example.com',
  headers: {'User-Agent': 'MCP-Client/1.0'},
);

// HTTP with all features
final transportConfig = TransportConfig.streamableHttp(
  baseUrl: 'https://api.example.com',
  headers: {'User-Agent': 'MCP-Client/1.0'},
  timeout: const Duration(seconds: 60),
  maxConcurrentRequests: 20,
  useHttp2: true,
  oauthConfig: OAuthConfig(
    authorizationEndpoint: 'https://auth.example.com/authorize',
    tokenEndpoint: 'https://auth.example.com/token',
    clientId: 'your-client-id',
  ),
  enableCompression: true,
  heartbeatInterval: const Duration(seconds: 60),
);

final clientResult = await McpClient.createAndConnect(
  config: config,
  transportConfig: transportConfig,
);
```

## Logging

The package uses the standard Dart logging package:

```dart
import 'package:logging/logging.dart';

// Set up logging
Logger.root.level = Level.INFO;
Logger.root.onRecord.listen((record) {
  print('${record.level.name}: ${record.time}: ${record.message}');
});

// Create logger for your component
final Logger _logger = Logger('mcp_client.example');

// Log messages at different levels
_logger.fine('Debugging information');
_logger.info('Important information');
_logger.warning('Warning message');
_logger.severe('Error message');

// Enable debug logging in client config
final config = McpClient.simpleConfig(
  name: 'My Client',
  version: '1.0.0',
  enableDebugLogging: true, // This enables detailed transport logging
);
```

## MCP Primitives

The MCP protocol defines three core primitives that clients can interact with:

| Primitive | Control               | Description                                         | Example Use                  |
|-----------|-----------------------|-----------------------------------------------------|------------------------------|
| Prompts   | User-controlled       | Interactive templates invoked by user choice        | Slash commands, menu options |
| Resources | Application-controlled| Contextual data managed by the client application   | File contents, API responses |
| Tools     | Model-controlled      | Functions exposed to the LLM to take actions        | API calls, data updates      |

## Advanced Usage

### Event Handling

Register for server-side notifications:

```dart
// Handle tools list changes
client.onToolsListChanged(() {
  _logger.debug('Tools list has changed');
  client.listTools().then((tools) {
    _logger.debug('New tools: ${tools.map((t) => t.name).join(', ')}');
  });
});

// Handle resources list changes
client.onResourcesListChanged(() {
  _logger.debug('Resources list has changed');
  client.listResources().then((resources) {
    _logger.debug('New resources: ${resources.map((r) => r.name).join(', ')}');
  });
});

// Handle prompts list changes
client.onPromptsListChanged(() {
  _logger.debug('Prompts list has changed');
  client.listPrompts().then((prompts) {
    _logger.debug('New prompts: ${prompts.map((p) => p.name).join(', ')}');
  });
});

// Handle server logging
client.onLogging((level, message, logger, data) {
  _logger.debug('Server log [$level]${logger != null ? " [$logger]" : ""}: $message');
  if (data != null) {
    _logger.debug('Additional data: $data');
  }
});
```

### Error Handling

The library uses Result types for robust error handling:

```dart
// Using createAndConnect with Result handling
final clientResult = await McpClient.createAndConnect(
  config: config,
  transportConfig: transportConfig,
);

final client = clientResult.fold(
  (client) {
    print('Successfully connected');
    return client;
  },
  (error) {
    print('Connection failed: $error');
    throw error;
  },
);

// Transport creation with Result handling
final transportResult = await McpClient.createStdioTransport(
  command: 'npx',
  arguments: ['-y', '@modelcontextprotocol/server-filesystem'],
);

await transportResult.fold(
  (transport) async {
    await client.connect(transport);
    print('Connected successfully');
  },
  (error) {
    print('Transport creation failed: $error');
  },
);

// Traditional try-catch for MCP protocol errors
try {
  await client.callTool('unknown-tool', {});
} on McpError catch (e) {
  print('MCP error (${e.code}): ${e.message}');
} catch (e) {
  print('Unexpected error: $e');
}
```

## Additional Examples

Check out the [example](https://github.com/app-appplayer/mcp_client/tree/main/example) directory for a complete sample application.

## Related Articles

- [Building a Model Context Protocol Server with Dart: Connecting to Claude Desktop](https://dev.to/mcpdevstudio/building-a-model-context-protocol-server-with-dart-connecting-to-claude-desktop-2aad)
- [Building a Model Context Protocol Client with Dart: A Comprehensive Guide](https://dev.to/mcpdevstudio/building-a-model-context-protocol-client-with-dart-a-comprehensive-guide-4fdg)
- [Integrating AI with Flutter: A Comprehensive Guide to mcp_llm
](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-a-comprehensive-guide-to-mcpllm-32f8)
- [Integrating AI with Flutter: Building Powerful Apps with LlmClient and mcp_client](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-building-powerful-apps-with-llmclient-and-mcpclient-5b0i)
- [Integrating AI with Flutter: Creating AI Services with LlmServer and mcp_server](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-creating-ai-services-with-llmserver-and-mcpserver-5084)
- [Integrating AI with Flutter: Connecting Multiple LLM Providers to MCP Ecosystem](https://dev.to/mcpdevstudio/integrating-ai-with-flutter-connecting-multiple-llm-providers-to-mcp-ecosystem-c3l)

## Resources

- [Model Context Protocol documentation](https://modelcontextprotocol.io)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Officially supported servers](https://github.com/modelcontextprotocol/servers)

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_client/issues).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.