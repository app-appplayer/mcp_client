import 'dart:io';
import 'dart:convert';
import 'package:mcp_client/mcp_client.dart';

/// MCP client example application
void main() async {
  final logger = Logger('mcp_client_example');
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    stderr.writeln('${record.level.name}: ${record.time}: ${record.message}');
  });

  // Create log file
  final logFile = File('mcp_client_example.log');
  final logSink = logFile.openWrite();

  logToConsoleAndFile('Starting MCP client example...', logger, logSink);

  try {
    // Method 1: Using production config with HTTP transport
    final config = McpClient.productionConfig(
      name: 'Example MCP Client',
      version: '1.0.0',
      capabilities: ClientCapabilities(
        roots: true,
        rootsListChanged: true,
        sampling: true,
      ),
    );

    logToConsoleAndFile('Client configuration initialized.', logger, logSink);

    // Connect to file system MCP server via STDIO
    logToConsoleAndFile(
      'Connecting to MCP file system server...',
      logger,
      logSink,
    );

    // Demonstrate production-ready transport with enhanced features
    final transportConfig = TransportConfig.stdio(
      command: 'npx',
      arguments: [
        '-y',
        '@modelcontextprotocol/server-filesystem',
        Directory.current.path,
      ],
    );

    // Production example: SSE transport with authentication and monitoring
    // final transportConfig = TransportConfig.sse(
    //   serverUrl: 'https://secure-api.example.com/sse',
    //   oauthConfig: OAuthConfig(
    //     authorizationEndpoint: 'https://auth.example.com/authorize',
    //     tokenEndpoint: 'https://auth.example.com/token',
    //     clientId: 'production-client',
    //     clientSecret: 'your-secret',
    //     scopes: ['mcp:read', 'mcp:write'],
    //   ),
    //   enableCompression: true,
    //   heartbeatInterval: const Duration(seconds: 30),
    //   maxMissedHeartbeats: 3,
    //   headers: {
    //     'User-Agent': 'MCP-Production-Client/2.0',
    //     'X-Client-Version': '2.0.0',
    //   },
    // );

    final clientResult = await McpClient.createAndConnect(
      config: config,
      transportConfig: transportConfig,
    );

    final client = clientResult.fold((c) {
      logToConsoleAndFile('Successfully connected to server!', logger, logSink);
      return c;
    }, (error) => throw Exception('Failed to connect: $error'));

    // Event handling is performed through client.onMessage stream

    // Check connection status
    logToConsoleAndFile('\n--- Server Connection Status ---', logger, logSink);
    logToConsoleAndFile('Connected to server', logger, logSink);

    // Check tool list
    final tools = await client.listTools();
    logToConsoleAndFile('\n--- Available Tools List ---', logger, logSink);

    if (tools.isEmpty) {
      logToConsoleAndFile('No tools available.', logger, logSink);
    } else {
      for (final tool in tools) {
        logToConsoleAndFile(
          'Tool: ${tool.name} - ${tool.description}',
          logger,
          logSink,
        );
      }
    }

    // Query current directory
    if (tools.any((tool) => tool.name == 'readdir')) {
      logToConsoleAndFile(
        '\n--- Current Directory Contents ---',
        logger,
        logSink,
      );

      final result = await client.callTool('readdir', {
        'path': Directory.current.path,
      });

      if (result.isError == true) {
        logToConsoleAndFile(
          'Error: ${(result.content.first as TextContent).text}',
          logger,
          logSink,
        );
      } else {
        final contentText = (result.content.first as TextContent).text;
        logToConsoleAndFile('Current directory contents:', logger, logSink);

        List<String> files = [];
        try {
          // Parse file list returned in JSON format
          final List<dynamic> jsonList = jsonDecode(contentText);
          files = jsonList.cast<String>();
        } catch (e) {
          // If simple text format, split by newline
          files =
              contentText
                  .split('\n')
                  .where((line) => line.trim().isNotEmpty)
                  .toList();
        }

        for (final file in files) {
          logToConsoleAndFile('- $file', logger, logSink);
        }

        // Read README.md file if it exists
        final readmeFile = files.firstWhere(
          (file) => file.toLowerCase() == 'readme.md',
          orElse: () => '',
        );

        if (readmeFile.isNotEmpty &&
            tools.any((tool) => tool.name == 'readFile')) {
          logToConsoleAndFile(
            '\n--- Reading README.md File ---',
            logger,
            logSink,
          );

          final readResult = await client.callTool('readFile', {
            'path': '${Directory.current.path}/$readmeFile',
          });

          if (readResult.isError == true) {
            logToConsoleAndFile(
              '오류: ${(readResult.content.first as TextContent).text}',
              logger,
              logSink,
            );
          } else {
            final content = (readResult.content.first as TextContent).text;

            // Display only partial content if too long
            if (content.length > 500) {
              logToConsoleAndFile(
                '${content.substring(0, 500)}...\n(Content too long, showing partial content)',
                logger,
                logSink,
              );
            } else {
              logToConsoleAndFile(content, logger, logSink);
            }
          }
        }
      }
    }

    try {
      // Check resource list
      final resources = await client.listResources();
      logToConsoleAndFile(
        '\n--- Available Resources List ---',
        logger,
        logSink,
      );

      if (resources.isEmpty) {
        logToConsoleAndFile('No resources available.', logger, logSink);
      } else {
        for (final resource in resources) {
          logToConsoleAndFile(
            'Resource: ${resource.name} (${resource.uri})',
            logger,
            logSink,
          );
        }

        // Read README.md file if file system resources exist
        final readmeFile = 'README.md';
        if (await File(readmeFile).exists() &&
            resources.any((resource) => resource.uri.startsWith('file:'))) {
          logToConsoleAndFile(
            '\n--- Reading README.md File as Resource ---',
            logger,
            logSink,
          );

          try {
            final fullPath = '${Directory.current.path}/$readmeFile';
            final resourceResult = await client.readResource(
              'file://$fullPath',
            );

            if (resourceResult.contents.isEmpty) {
              logToConsoleAndFile('Resource has no content.', logger, logSink);
            } else {
              final content = resourceResult.contents.first.text ?? '';

              // Display only partial content if too long
              if (content.length > 500) {
                logToConsoleAndFile(
                  '${content.substring(0, 500)}...\n(내용이 너무 길어 일부만 표시)',
                  logger,
                  logSink,
                );
              } else {
                logToConsoleAndFile(content, logger, logSink);
              }
            }
          } catch (e) {
            logToConsoleAndFile(
              'Error reading file as resource: $e',
              logger,
              logSink,
            );
          }
        }
      }
    } catch (e) {
      logToConsoleAndFile(
        'Resource listing feature not supported: $e',
        logger,
        logSink,
      );
    }

    // Wait briefly before exiting
    await Future.delayed(Duration(seconds: 2));
    logToConsoleAndFile('\nExample execution completed.', logger, logSink);

    // Close client connection
    client.disconnect();
    logToConsoleAndFile('Client connection closed.', logger, logSink);
  } catch (e, stackTrace) {
    logToConsoleAndFile('오류: $e', logger, logSink);
    logToConsoleAndFile('Stack trace: $stackTrace', logger, logSink);
  } finally {
    // Close log file
    await logSink.flush();
    await logSink.close();
  }
}

/// Log to both console and file simultaneously
void logToConsoleAndFile(String message, Logger logger, IOSink logSink) {
  // Output log to console
  logger.info(message);

  // Also log to file
  logSink.writeln(message);
}
