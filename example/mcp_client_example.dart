import 'dart:io';
import 'package:mcp_client/mcp_client.dart';

final _logger = Logger('mcp_client_example');

/// Example MCP client application that connects to a filesystem server and demonstrates key functionality
void main() async {
  // Set up logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln('${record.level.name}: ${record.time}: ${record.message}');
  });

  // Create a log file for output
  final logFile = File('mcp_client_example.log');
  final logSink = logFile.openWrite();

  logToFile('Starting MCP client example...', logSink);

  // Method 1: Using createAndConnect with TransportConfig
  final config = McpClient.simpleConfig(
    name: 'Example MCP Client',
    version: '1.0.0',
    enableDebugLogging: true,
  );

  // Example of using different transport types with unified API
  final transportConfig = TransportConfig.stdio(
    command: 'npx',
    arguments: [
      '-y',
      '@modelcontextprotocol/server-filesystem',
      Directory.current.path,
    ],
  );

  // Alternative: SSE transport with enhanced features
  // final transportConfig = TransportConfig.sse(
  //   serverUrl: 'http://localhost:3000/sse',
  //   bearerToken: 'your-token', // Bearer token authentication
  //   enableCompression: true,   // Message compression
  //   heartbeatInterval: const Duration(seconds: 30), // Connection monitoring
  // );

  // Alternative: HTTP transport with full configuration
  // final transportConfig = TransportConfig.streamableHttp(
  //   baseUrl: 'https://api.example.com',
  //   oauthConfig: OAuthConfig(
  //     authorizationEndpoint: 'https://auth.example.com/authorize',
  //     tokenEndpoint: 'https://auth.example.com/token',
  //     clientId: 'your-client-id',
  //   ),
  //   enableCompression: true,
  //   heartbeatInterval: const Duration(seconds: 60),
  //   useHttp2: true,
  //   maxConcurrentRequests: 20,
  // );

  logToFile('Connecting to MCP filesystem server...', logSink);

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  final client = clientResult.fold((c) {
    logToFile('Successfully connected to server!', logSink);
    return c;
  }, (error) => throw Exception('Failed to connect: $error'));

  try {
    // Note: Event handling is done via client.onMessage stream

    // List available tools
    logToFile('\n--- Available Tools ---', logSink);
    final tools = await client.listTools();
    if (tools.isEmpty) {
      logToFile('No tools available.', logSink);
    } else {
      for (final tool in tools) {
        logToFile('Tool: ${tool.name} - ${tool.description}', logSink);
      }
    }

    // List available resources
    logToFile('\n--- Available Resources ---', logSink);
    final resources = await client.listResources();
    if (resources.isEmpty) {
      logToFile('No resources available.', logSink);
    } else {
      for (final resource in resources) {
        logToFile('Resource: ${resource.name} (${resource.uri})', logSink);
      }
    }

    // Example: List directory contents using a tool
    if (tools.any((tool) => tool.name == 'readdir')) {
      logToFile('\n--- Directory Contents ---', logSink);
      final result = await client.callTool('readdir', {
        'path': Directory.current.path,
      });

      // Process and display the result
      if (result.isError == true) {
        logToFile(
          'Error reading directory: ${(result.content.first as TextContent).text}',
          logSink,
        );
      } else {
        logToFile('Current directory contents:', logSink);
        logToFile((result.content.first as TextContent).text, logSink);
      }
    }

    // Example: Read a file using a resource if available
    final exampleFilePath = 'README.md';
    if (await File(exampleFilePath).exists()) {
      logToFile('\n--- Reading File ---', logSink);
      try {
        final resourceResult = await client.readResource(
          'file://${Directory.current.path}/$exampleFilePath',
        );

        if (resourceResult.contents.isNotEmpty) {
          final content = resourceResult.contents.first;
          final text = content.text ?? '';
          logToFile('File content (first 200 chars):', logSink);
          logToFile(
            '${text.length > 200 ? text.substring(0, 200) : text}...',
            logSink,
          );
        } else {
          logToFile('No content returned from resource.', logSink);
        }
      } catch (e) {
        logToFile('Error reading file: $e', logSink);
      }
    }

    // Wait a bit for any pending operations to complete
    await Future.delayed(Duration(seconds: 1));

    logToFile('\nExample completed successfully!', logSink);
  } catch (e) {
    logToFile('Error: $e', logSink);
  } finally {
    // Make sure to disconnect before exiting
    logToFile('Disconnecting client...', logSink);
    client.disconnect();
    logToFile('Disconnected!', logSink);

    // Close the log file
    await logSink.flush();
    await logSink.close();

    // Exit the application
    exit(0);
  }
}

/// Log to file instead of stdout to avoid interfering with STDIO transport
void logToFile(String message, IOSink logSink) {
  // Log to stderr (which doesn't interfere with STDIO protocol on stdin/stdout)
  _logger.info(message);

  // Also log to file
  logSink.writeln(message);
}
