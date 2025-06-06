import 'package:mcp_client/mcp_client.dart';

/// Modern example showing how to use the updated MCP client with Result types,
/// sealed classes, and modern Dart patterns.
Future<void> main() async {
  // Initialize logging
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });
  final logger = Logger('client_example');

  logger.info('Starting modern MCP client example');

  // Example 1: Simple client configuration
  await _simpleClientExample();

  // Example 2: Production client configuration with error handling
  await _productionClientExample();

  // Example 3: Multiple transport types
  await _transportExamples();
}

/// Simple client example using basic configuration
Future<void> _simpleClientExample() async {
  final logger = Logger('simple_example');

  // Create a simple client
  final client = Client(
    name: 'SimpleClient',
    version: '1.0.0',
    capabilities: ClientCapabilities(roots: true, sampling: true),
  );

  // Create transport
  final transportResult = await McpClient.createStdioTransport(
    command: 'python',
    arguments: ['-m', 'mcp_server_example'],
  );

  // Connect client using Result pattern
  final result = transportResult.fold((transport) async {
    try {
      await client.connect(transport);
      return client;
    } catch (e) {
      return Exception('Connection failed: $e');
    }
  }, (error) async => error);

  final resultValue = await result;
  if (resultValue is Client) {
    logger.info('✅ Client connected successfully');

    // Use the client
    try {
      final tools = await resultValue.listTools();
      logger.info('Available tools: ${tools.map((t) => t.name).join(', ')}');

      final resources = await resultValue.listResources();
      logger.info(
        'Available resources: ${resources.map((r) => r.uri).join(', ')}',
      );
    } catch (e) {
      logger.severe('Error using client: $e');
    } finally {
      resultValue.disconnect();
      logger.info('Client disconnected');
    }
  } else {
    logger.severe('❌ Failed to connect client: $resultValue');
  }
}

/// Production client example with comprehensive error handling
Future<void> _productionClientExample() async {
  final logger = Logger('production_example');

  // Create production client
  final client = Client(
    name: 'ProductionClient',
    version: '2.0.0',
    capabilities: ClientCapabilities(
      roots: true,
      rootsListChanged: true,
      sampling: true,
    ),
  );

  // Create SSE transport
  final transportResult = await McpClient.createSseTransport(
    serverUrl: 'http://localhost:8080/sse',
    headers: {'Authorization': 'Bearer your-token-here'},
  );

  logger.info('Creating production client...');

  final result = transportResult.fold((transport) async {
    try {
      await client.connect(transport);
      return client;
    } catch (e) {
      return Exception('Connection failed: $e');
    }
  }, (error) async => error);

  final resultValue = await result;
  if (resultValue is Client) {
    logger.info('✅ Production client connected');

    // Note: Event listeners would be set up via client.onMessage stream
    logger.info('Event handling available via client.onMessage stream');

    // Example operations with error handling
    await _performClientOperations(resultValue, logger);
  } else {
    logger.severe('❌ Failed to create production client: $resultValue');
  }
}

/// Perform various client operations with error handling
Future<void> _performClientOperations(Client client, Logger logger) async {
  try {
    // List and call tools
    final tools = await client.listTools();
    if (tools.isNotEmpty) {
      logger.info('Calling tool: ${tools.first.name}');
      final result = await client.callTool(tools.first.name, {});
      logger.info('Tool result: $result');
    }

    // Work with resources
    final resources = await client.listResources();
    if (resources.isNotEmpty) {
      logger.info('Reading resource: ${resources.first.uri}');
      final content = await client.readResource(resources.first.uri);
      logger.info('Resource content length: ${content.contents.length}');
    }

    // Note: Health check not available in current API
    logger.info('Client operations completed successfully');
  } catch (e, stackTrace) {
    logger.severe('Error in operations: $e', e, stackTrace);
  } finally {
    client.disconnect();
    logger.info('Client operations completed');
  }
}

/// Examples of different transport types
Future<void> _transportExamples() async {
  final logger = Logger('transport_examples');

  // STDIO transport example
  logger.info('Creating STDIO transport...');
  final stdioResult = await McpClient.createStdioTransport(
    command: 'node',
    arguments: ['server.js'],
  );

  stdioResult.fold(
    (transport) {
      logger.info('✅ STDIO transport created');
      // Use transport...
    },
    (error) {
      logger.severe('❌ Failed to create STDIO transport: $error');
    },
  );

  // SSE transport example
  logger.info('Creating SSE transport...');
  final sseResult = await McpClient.createSseTransport(
    serverUrl: 'https://api.example.com/mcp',
    headers: {'Authorization': 'Bearer token', 'X-API-Version': '2024-11-05'},
  );

  sseResult.fold(
    (transport) {
      logger.info('✅ SSE transport created');
      // Use transport...
    },
    (error) {
      logger.severe('❌ Failed to create SSE transport: $error');
    },
  );
}
