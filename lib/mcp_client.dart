import 'src/client/client.dart';
import 'src/transport/transport.dart';

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
  static SseClientTransport createSseTransport({
    required String serverUrl,
    Map<String, String>? headers,
  }) {
    return SseClientTransport(
      serverUrl: serverUrl,
      headers: headers,
    );
  }
}