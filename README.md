# MCP Client

A Dart plugin for implementing [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) clients. This plugin allows Flutter applications to connect with MCP servers and access data, functionality, and interaction patterns from Large Language Model (LLM) applications in a standardized way.

## Features

- Create MCP clients with standardized protocol support
- Access data through **Resources**
- Execute functionality through **Tools**
- Utilize interaction patterns through **Prompts**
- Support for **Roots** management
- Support for **Sampling** (LLM text generation)
- Track **Progress** of long-running operations
- **Health Monitoring** of server status
- **Operation Cancellation** for ongoing tasks
- Multiple transport layers:
  - Standard I/O for local process communication
  - Server-Sent Events (SSE) for HTTP-based communication
- Cross-platform support: Android, iOS, web, Linux, Windows, macOS

## Protocol Version

This package implements the Model Context Protocol (MCP) specification version `2024-11-05`.

The protocol version is crucial for ensuring compatibility between MCP clients and servers. Each release of this package may support different protocol versions, so it's important to:

- Check the CHANGELOG.md for protocol version updates
- Ensure client and server protocol versions are compatible
- Stay updated with the latest MCP specification

### Version Compatibility

- Supported protocol version: 2024-11-05
- Compatibility: Tested with latest MCP server implementations

For the most up-to-date information on protocol versions and compatibility, refer to the [Model Context Protocol specification](https://spec.modelcontextprotocol.io).

## Getting Started

### Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mcp_client: ^0.1.6
```

Or install via command line:

```bash
dart pub add mcp_client
```

### Basic Usage

```dart
import 'package:mcp_client/mcp_client.dart';

void main() async {
  // Create a client
  final client = McpClient.createClient(
    name: 'Example Client',
    version: '1.0.0',
    capabilities: ClientCapabilities(
      roots: true,
      rootsListChanged: true,
      sampling: true,
    ),
  );

  // Create a transport
  final transport = await McpClient.createStdioTransport(
    command: 'npx',
    arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/path/to/allowed/directory'],
  );
  
  // Connect to the server
  await client.connect(transport);
  
  // List available tools on the server
  final tools = await client.listTools();
  _logger.debug('Available tools: ${tools.map((t) => t.name).join(', ')}');
  
  // Call a tool
  final result = await client.callTool('calculator', {
    'operation': 'add',
    'a': 5,
    'b': 3,
  });
  _logger.debug('Result: ${(result.content.first as TextContent).text}');
  
  // Disconnect when done
  client.disconnect();
}
```

## Core Concepts

### Client

The `Client` is your core interface to the MCP protocol. It handles connection management, protocol compliance, and message routing:

```dart
final client = McpClient.createClient(
  name: 'My App',
  version: '1.0.0',
  capabilities: ClientCapabilities(
    roots: true,
    rootsListChanged: true,
    sampling: true,
  ),
);
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

### Standard I/O

For command-line tools and direct integrations:

```dart
final transport = await McpClient.createStdioTransport(
command: 'npx',
arguments: ['-y', '@modelcontextprotocol/server-filesystem', '/path/to/allowed/directory'],
workingDirectory: '/path/to/working/directory',
environment: {'ENV_VAR': 'value'},
);
await client.connect(transport);
```

### Server-Sent Events (SSE)

For HTTP-based communication:

```dart
final transport = McpClient.createSseTransport(
  serverUrl: 'http://localhost:8080/sse',
  headers: {'Authorization': 'Bearer token'},
);
await client.connect(transport);
```

## Logging

The package includes a built-in logging utility:

```dart
/// Logging
final Logger _logger = Logger.getLogger('mcp_client.test');
_logger.setLevel(LogLevel.debug);

// Configure logging
_logger.configure(level: LogLevel.debug, includeTimestamp: true, useColor: true);

// Log messages at different levels
_logger.debug('Debugging information');
_logger.info('Important information');
_logger.warning('Warning message');
_logger.error('Error message');
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

```dart
try {
  await client.callTool('unknown-tool', {});
} on McpError catch (e) {
  _logger.debug('MCP error (${e.code}): ${e.message}');
} catch (e) {
  _logger.debug('Unexpected error: $e');
}
```

## Additional Examples

Check out the [example](https://github.com/app-appplayer/mcp_client/tree/main/example) directory for a complete sample application.

## Resources

- [Model Context Protocol documentation](https://modelcontextprotocol.io)
- [Model Context Protocol specification](https://spec.modelcontextprotocol.io)
- [Officially supported servers](https://github.com/modelcontextprotocol/servers)

## Issues and Feedback

Please file any issues, bugs, or feature requests in our [issue tracker](https://github.com/app-appplayer/mcp_client/issues).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.