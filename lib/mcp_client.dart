import 'src/client/client.dart';
import 'src/transport/transport.dart';

export 'src/models/models.dart';
export 'src/client/client.dart';
export 'src/transport/transport.dart';
export 'logger.dart';

typedef MCPClient = McpClient;
/// Main plugin class for MCP Client implementation
class McpClient {
  /// Create a new MCP client with the specified configuration
  static Client createClient({
    required String name,
    required String version,
    ClientCapabilities? capabilities,
  }) {
    return Client(
      name: name,
      version: version,
      capabilities: capabilities ?? const ClientCapabilities(),
    );
  }

  static Future<Client> createAndConnectClient({
    required String name,
    required String version,
    required ClientTransport transport,
    ClientCapabilities? capabilities,
    int maxRetries = 3,
  }) async {
    final client = createClient(
      name: name,
      version: version,
      capabilities: capabilities,
    );

    await client.connectWithRetry(transport, maxRetries: maxRetries);
    return client;
  }

  /// Create a stdio transport for the client
  static Future<StdioClientTransport> createStdioTransport({
    required String command,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return StdioClientTransport.create(
      command: command,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  /// Create an SSE transport for the client
  static Future<SseClientTransport> createSseTransport({
    required String serverUrl,
    Map<String, String>? headers,
  }) {
    return SseClientTransport.create(
      serverUrl: serverUrl,
      headers: headers,
    );
  }
}