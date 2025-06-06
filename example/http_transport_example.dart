import 'package:mcp_client/mcp_client.dart';

/// Example demonstrating different transport configurations with McpClient
void main() async {
  final logger = Logger('http_transport_example');
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  // Example 1: Simple HTTP transport without authentication
  await exampleSimpleHttp(logger);

  // Example 2: HTTP transport with headers and configuration
  await exampleConfiguredHttp(logger);

  // Example 3: HTTP transport with OAuth authentication
  await exampleOAuthHttp(logger);

  // Example 4: Comparing different transport types
  await exampleCompareTransports(logger);
}

/// Example 1: Simple HTTP transport
Future<void> exampleSimpleHttp(Logger logger) async {
  logger.info('\n=== Example 1: Simple HTTP Transport ===');

  final config = McpClient.simpleConfig(
    name: 'Simple HTTP Client',
    version: '1.0.0',
    enableDebugLogging: true,
  );

  // Use HTTP transport with minimal configuration
  final transportConfig = TransportConfig.streamableHttp(
    baseUrl: 'http://localhost:8080',
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via simple HTTP transport');

      try {
        // List available tools
        final tools = await client.listTools();
        logger.info('Available tools: ${tools.map((t) => t.name).join(', ')}');

        // List resources
        final resources = await client.listResources();
        logger.info('Available resources: ${resources.length}');
      } finally {
        client.disconnect();
        logger.info('Disconnected from simple HTTP transport');
      }
    },
    (error) {
      logger.severe('Failed to connect via simple HTTP: $error');
    },
  );
}

/// Example 2: Configured HTTP transport with all options
Future<void> exampleConfiguredHttp(Logger logger) async {
  logger.info('\n=== Example 2: Configured HTTP Transport ===');

  final config = McpClient.productionConfig(
    name: 'Production HTTP Client',
    version: '2.0.0',
  );

  // Use HTTP transport with full configuration
  final transportConfig = TransportConfig.streamableHttp(
    baseUrl: 'https://api.example.com',
    headers: {
      'User-Agent': 'MCP-Client/2.0',
      'X-API-Key': 'your-api-key',
      'Accept-Language': 'en-US',
    },
    timeout: const Duration(seconds: 45),
    maxConcurrentRequests: 20,
    useHttp2: true,
  );

  final clientResult = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  await clientResult.fold(
    (client) async {
      logger.info('Connected via configured HTTP/2 transport');

      try {
        // Demonstrate concurrent operations
        final futures = <Future>[];

        // Make multiple concurrent requests
        for (int i = 0; i < 5; i++) {
          futures.add(
            client.listTools().then((tools) {
              logger.info('Request $i completed, found ${tools.length} tools');
            }),
          );
        }

        await Future.wait(futures);
        logger.info('All concurrent requests completed');
      } finally {
        client.disconnect();
        logger.info('Disconnected from configured HTTP transport');
      }
    },
    (error) {
      logger.severe('Failed to connect via configured HTTP: $error');
    },
  );
}

/// Example 3: HTTP transport with OAuth authentication
Future<void> exampleOAuthHttp(Logger logger) async {
  logger.info('\n=== Example 3: OAuth HTTP Transport ===');

  final config = McpClient.productionConfig(
    name: 'OAuth HTTP Client',
    version: '1.0.0',
  );

  // First, create the transport manually to demonstrate OAuth flow
  final oauthConfig = OAuthConfig(
    authorizationEndpoint: 'https://auth.example.com/authorize',
    tokenEndpoint: 'https://auth.example.com/token',
    clientId: 'mcp-client-example',
    clientSecret: 'your-client-secret',
    redirectUri: 'http://localhost:8080/callback',
    scopes: ['mcp:read', 'mcp:write'],
    grantType: OAuthGrantType.clientCredentials,
  );

  try {
    final transport = await StreamableHttpClientTransport.create(
      baseUrl: 'https://oauth-api.example.com',
      oauthConfig: oauthConfig,
      headers: {'User-Agent': 'MCP-OAuth-Client/1.0'},
      maxConcurrentRequests: 10,
    );

    logger.info('OAuth transport created, initiating connection...');

    final client = McpClient.createClient(config);
    await client.connect(transport);

    logger.info('Connected with OAuth authentication');

    try {
      // OAuth-protected operations
      await client.callTool('secure-operation', {
        'action': 'read_sensitive_data',
      });

      logger.info('Secure operation completed');
    } finally {
      client.disconnect();
      logger.info('Disconnected from OAuth transport');
    }
  } catch (e) {
    logger.severe('OAuth connection failed: $e');
  }
}

/// Example 4: Comparing different transport types
Future<void> exampleCompareTransports(Logger logger) async {
  logger.info('\n=== Example 4: Comparing Transport Types ===');

  final config = McpClient.simpleConfig(
    name: 'Multi-Transport Client',
    version: '1.0.0',
  );

  // Define different transport configurations
  final transports = [
    (
      name: 'STDIO',
      config: TransportConfig.stdio(
        command: 'npx',
        arguments: ['-y', '@modelcontextprotocol/server-example'],
      ),
    ),
    (
      name: 'SSE',
      config: TransportConfig.sse(
        serverUrl: 'http://localhost:3000/sse',
        headers: {'Authorization': 'Bearer token'},
      ),
    ),
    (
      name: 'HTTP',
      config: TransportConfig.streamableHttp(
        baseUrl: 'http://localhost:8080',
        useHttp2: false,
      ),
    ),
  ];

  // Test each transport
  for (final transport in transports) {
    logger.info('\nTesting ${transport.name} transport...');

    final clientResult = await McpClient.createAndConnect(
      config: config,
      transportConfig: transport.config,
    );

    await clientResult.fold(
      (client) async {
        logger.info('✓ ${transport.name} connected successfully');

        // Quick test
        try {
          final tools = await client.listTools();
          logger.info('  Found ${tools.length} tools');
        } catch (e) {
          logger.warning('  Error listing tools: $e');
        }

        client.disconnect();
      },
      (error) {
        logger.warning('✗ ${transport.name} failed: $error');
      },
    );
  }

  logger.info('\nTransport comparison complete');
}
