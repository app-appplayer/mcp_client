import 'package:mcp_client/mcp_client.dart';

/// Example demonstrating unified transport configurations
void main() async {
  final logger = Logger('unified_transport_example');
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  // Example 1: Basic SSE transport
  await exampleBasicSse(logger);

  // Example 2: SSE with OAuth authentication
  await exampleSseWithAuth(logger);

  // Example 3: SSE with compression
  await exampleSseWithCompression(logger);

  // Example 4: SSE with heartbeat
  await exampleSseWithHeartbeat(logger);

  // Example 5: HTTP with all features
  await exampleHttpWithAllFeatures(logger);
}

/// Example 1: Basic SSE transport
Future<void> exampleBasicSse(Logger logger) async {
  logger.info('\n=== Example 1: Basic SSE Transport ===');

  final config = McpClient.simpleConfig(
    name: 'Basic SSE Client',
    version: '1.0.0',
  );

  // Basic SSE - no special features
  final transportConfig = TransportConfig.sse(
    serverUrl: 'http://localhost:3000/sse',
    headers: {'User-Agent': 'MCP-Client/1.0'},
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via basic SSE transport');
      client.disconnect();
    },
    (error) {
      logger.severe('Failed to connect: $error');
    },
  );
}

/// Example 2: SSE with OAuth authentication
Future<void> exampleSseWithAuth(Logger logger) async {
  logger.info('\n=== Example 2: SSE with OAuth Authentication ===');

  final config = McpClient.simpleConfig(
    name: 'OAuth SSE Client',
    version: '1.0.0',
  );

  // SSE with OAuth - automatically uses SseAuthClientTransport
  final transportConfig = TransportConfig.sse(
    serverUrl: 'https://secure-api.example.com/sse',
    headers: {'User-Agent': 'MCP-Client/1.0'},
    oauthConfig: OAuthConfig(
      authorizationEndpoint: 'https://auth.example.com/authorize',
      tokenEndpoint: 'https://auth.example.com/token',
      clientId: 'mcp-client',
      clientSecret: 'secret',
    ),
    // OR use bearer token directly
    bearerToken: 'your-bearer-token',
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via OAuth SSE transport');
      client.disconnect();
    },
    (error) {
      logger.severe('OAuth SSE connection failed: $error');
    },
  );
}

/// Example 3: SSE with compression
Future<void> exampleSseWithCompression(Logger logger) async {
  logger.info('\n=== Example 3: SSE with Compression ===');

  final config = McpClient.simpleConfig(
    name: 'Compressed SSE Client',
    version: '1.0.0',
  );

  // SSE with compression - automatically uses SseCompressedClientTransport
  final transportConfig = TransportConfig.sse(
    serverUrl: 'http://localhost:3000/sse',
    headers: {'Accept-Encoding': 'gzip, deflate'},
    enableCompression: true,
    enableGzip: true,
    enableDeflate: true,
    compressionLevel: 6,
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via compressed SSE transport');
      client.disconnect();
    },
    (error) {
      logger.severe('Compressed SSE connection failed: $error');
    },
  );
}

/// Example 4: SSE with heartbeat
Future<void> exampleSseWithHeartbeat(Logger logger) async {
  logger.info('\n=== Example 4: SSE with Heartbeat ===');

  final config = McpClient.simpleConfig(
    name: 'Heartbeat SSE Client',
    version: '1.0.0',
  );

  // SSE with heartbeat - automatically uses SseHeartbeatClientTransport
  final transportConfig = TransportConfig.sse(
    serverUrl: 'http://localhost:3000/sse',
    heartbeatInterval: const Duration(seconds: 30),
    connectionTimeout: const Duration(seconds: 60),
    maxMissedHeartbeats: 3,
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via heartbeat SSE transport');

      // Keep connection alive for a bit to see heartbeat in action
      await Future.delayed(const Duration(seconds: 5));

      client.disconnect();
    },
    (error) {
      logger.severe('Heartbeat SSE connection failed: $error');
    },
  );
}

/// Example 5: HTTP with all features
Future<void> exampleHttpWithAllFeatures(Logger logger) async {
  logger.info('\n=== Example 5: HTTP with All Features ===');

  final config = McpClient.productionConfig(
    name: 'Full-Featured HTTP Client',
    version: '1.0.0',
  );

  // HTTP with OAuth, compression, and heartbeat
  final transportConfig = TransportConfig.streamableHttp(
    baseUrl: 'https://api.example.com',
    headers: {
      'User-Agent': 'MCP-Client/1.0',
      'Accept-Encoding': 'gzip, deflate',
    },
    timeout: const Duration(seconds: 45),
    maxConcurrentRequests: 20,
    useHttp2: true,
    oauthConfig: OAuthConfig(
      authorizationEndpoint: 'https://auth.example.com/authorize',
      tokenEndpoint: 'https://auth.example.com/token',
      clientId: 'mcp-client',
      scopes: ['mcp:read', 'mcp:write'],
    ),
    enableCompression: true,
    heartbeatInterval: const Duration(seconds: 60),
    maxMissedHeartbeats: 2,
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via full-featured HTTP transport');

      try {
        // Test the connection
        final tools = await client.listTools();
        logger.info('Found ${tools.length} tools');
      } catch (e) {
        logger.warning('Error testing connection: $e');
      }

      client.disconnect();
    },
    (error) {
      logger.severe('Full-featured HTTP connection failed: $error');
    },
  );
}

/// Example 6: Feature priority demonstration
Future<void> exampleFeaturePriority(Logger logger) async {
  logger.info('\n=== Example 6: Feature Priority ===');

  final config = McpClient.simpleConfig(
    name: 'Priority Test Client',
    version: '1.0.0',
  );

  // When multiple features are enabled, OAuth takes priority
  final transportConfig = TransportConfig.sse(
    serverUrl: 'https://api.example.com/sse',
    bearerToken: 'token123', // OAuth feature (highest priority)
    enableCompression: true, // Compression feature
    heartbeatInterval: const Duration(seconds: 30), // Heartbeat feature
  );

  // This will use SseAuthClientTransport because OAuth has highest priority
  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected - OAuth transport was selected due to priority');
      client.disconnect();
    },
    (error) {
      logger.severe('Priority test failed: $error');
    },
  );
}
