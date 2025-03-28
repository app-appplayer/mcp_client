import 'dart:io';
import 'package:mcp_client/logger.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_client/src/client/client.dart';
import 'package:mcp_client/src/models/models.dart';

/// Example MCP client application that connects to a filesystem server and demonstrates key functionality
void main() async {
  // Set up logging to use stderr instead of stdout
  log.setLevel(LogLevel.debug);

  // Create a log file for output
  final logFile = File('mcp_client_example.log');
  final logSink = logFile.openWrite();

  logToFile('Starting MCP client example...', logSink);

  // Create a client with root and sampling capabilities
  final client = McpClient.createClient(
    name: 'Example MCP Client',
    version: '1.0.0',
    capabilities: ClientCapabilities(
      roots: true,
      rootsListChanged: true,
      sampling: true,
    ),
  );

  // Create a StdioTransport to connect to an MCP filesystem server
  // Please ensure you have Node.js and npx installed
  final transport = await McpClient.createStdioTransport(
    command: 'npx',
    arguments: ['-y', '@modelcontextprotocol/server-filesystem', Directory.current.path],
  );

  logToFile('Connecting to MCP filesystem server...', logSink);

  try {
    // Connect to the server
    await client.connect(transport);
    logToFile('Successfully connected to server!', logSink);

    // Register notification handlers
    client.onToolsListChanged(() {
      logToFile('Tools list has changed!', logSink);
    });

    client.onResourcesListChanged(() {
      logToFile('Resources list has changed!', logSink);
    });

    client.onLogging((level, message, logger, data) {
      logToFile('Server log [$level]: $message', logSink);
    });

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
      final result = await client.callTool('readdir', {'path': Directory.current.path});

      // Process and display the result
      if (result.isError == true) {
        logToFile('Error reading directory: ${(result.content.first as TextContent).text}', logSink);
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
        final resourceResult = await client.readResource('file://${Directory.current.path}/$exampleFilePath');

        if (resourceResult.contents.isNotEmpty) {
          final content = resourceResult.contents.first;
          logToFile('File content (first 200 chars):', logSink);
          logToFile('${content.text?.substring(0, content.text!.length > 200 ? 200 : content.text!.length)}...', logSink);
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
  stderr.writeln(message);

  // Also log to file
  logSink.writeln(message);
}