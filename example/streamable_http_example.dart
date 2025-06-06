import 'package:mcp_client/mcp_client.dart';

void main() async {
  // Method 1: Using createAndConnect with TransportConfig.streamableHttp
  final config = McpClient.simpleConfig(
    name: 'HTTP Example Client',
    version: '1.0.0',
    enableDebugLogging: true,
  );

  final transportConfig = TransportConfig.streamableHttp(
    baseUrl: 'https://api.example.com',
    headers: {
      'Authorization': 'Bearer your-token',
      'X-API-Key': 'your-api-key',
    },
    timeout: const Duration(seconds: 60),
    maxConcurrentRequests: 20,
    useHttp2: true,
  );

  final result = await McpClient.createAndConnect(
    config: config,
    transportConfig: transportConfig,
  );

  result.fold(
    (client) async {
      print('Connected successfully via HTTP transport');

      // Use the client
      final tools = await client.listTools();
      print('Available tools: ${tools.map((t) => t.name).join(', ')}');

      // Don't forget to disconnect
      client.disconnect();
    },
    (error) {
      print('Connection failed: $error');
    },
  );

  // Method 2: Manual transport creation and connection
  final client2 = McpClient.createClient(config);

  final transportResult = await McpClient.createStreamableHttpTransport(
    baseUrl: 'https://api.example.com',
    headers: {'Authorization': 'Bearer your-token'},
    timeout: const Duration(seconds: 30),
    maxConcurrentRequests: 10,
    useHttp2: false, // Explicitly disable HTTP/2
  );

  await transportResult.fold(
    (transport) async {
      await client2.connect(transport);
      print('Connected via manually created HTTP transport');

      // Use the client
      final resources = await client2.listResources();
      print('Available resources: ${resources.map((r) => r.name).join(', ')}');

      client2.disconnect();
    },
    (error) {
      print('Transport creation failed: $error');
    },
  );

  // Method 3: For OAuth-enabled HTTP transport
  final oauthTransport = await StreamableHttpClientTransport.create(
    baseUrl: 'https://oauth-api.example.com',
    oauthConfig: OAuthConfig(
      authorizationEndpoint: 'https://auth.example.com/authorize',
      tokenEndpoint: 'https://auth.example.com/token',
      clientId: 'your-client-id',
      clientSecret: 'your-client-secret',
      scopes: ['read', 'write'],
    ),
    headers: {'User-Agent': 'MCP HTTP Client/1.0'},
    maxConcurrentRequests: 15,
  );

  final client3 = McpClient.createClient(config);
  await client3.connect(oauthTransport);

  print('Connected with OAuth-enabled HTTP transport');

  // The transport will handle OAuth authentication automatically
  final result3 = await client3.callTool('protected-tool', {
    'parameter': 'value',
  });

  print('Tool result: ${result3.content.first}');

  client3.disconnect();
}
