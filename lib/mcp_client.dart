import 'package:meta/meta.dart';
import 'package:logging/logging.dart';

import 'src/client/client.dart';
import 'src/transport/transport.dart';
import 'src/transport/streamable_http_transport.dart';
import 'src/common/result.dart';
import 'src/models/models.dart';
import 'src/auth/mcp_oauth.dart';
import 'src/auth/oauth.dart';

export 'src/models/models.dart';
export 'src/client/client.dart';
export 'src/client/delegating_client.dart';
export 'src/transport/transport.dart';
export 'src/transport/streamable_http_transport.dart';
export 'src/transport/legacy_sse.dart';
export 'src/protocol/protocol.dart';
export 'src/protocol/request_meta.dart';
export 'src/protocol/multi_round_trip.dart';
export 'src/protocol/tasks.dart';
export 'src/auth/mcp_oauth.dart';
export 'src/auth/oauth.dart';
export 'src/auth/oauth_client.dart';
export 'src/auth/oauth_discovery.dart';
export 'src/common/result.dart';
export 'src/common/connection_state.dart';
export 'logger.dart';

/// Configuration for creating MCP clients
@immutable
class McpClientConfig {
  /// The name of the client application
  final String name;

  /// The version of the client application
  final String version;

  /// Spec 2025-11-25+: optional human-readable description of the client
  /// implementation, forwarded to `clientInfo.description` on initialize.
  final String? description;

  /// The capabilities supported by the client
  final ClientCapabilities capabilities;

  /// Protocol revision to speak. Defaults to this build's default version.
  final String? protocolVersion;

  /// Maximum number of connection retry attempts
  final int maxRetries;

  /// Delay between connection retry attempts
  final Duration retryDelay;

  /// Timeout for individual requests
  final Duration requestTimeout;

  /// Whether to enable debug logging
  final bool enableDebugLogging;

  /// Which protocol era to speak ([ProtocolEra.auto] probes the server).
  final ProtocolEra era;

  const McpClientConfig({
    required this.name,
    required this.version,
    this.description,
    this.capabilities = const ClientCapabilities(),
    this.protocolVersion,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 30),
    this.enableDebugLogging = false,
    this.era = ProtocolEra.auto,
  });

  /// Creates a copy of this config with the given fields replaced
  McpClientConfig copyWith({
    String? name,
    String? version,
    String? description,
    ClientCapabilities? capabilities,
    String? protocolVersion,
    int? maxRetries,
    Duration? retryDelay,
    Duration? requestTimeout,
    bool? enableDebugLogging,
    ProtocolEra? era,
  }) {
    return McpClientConfig(
      name: name ?? this.name,
      version: version ?? this.version,
      description: description ?? this.description,
      capabilities: capabilities ?? this.capabilities,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      maxRetries: maxRetries ?? this.maxRetries,
      retryDelay: retryDelay ?? this.retryDelay,
      requestTimeout: requestTimeout ?? this.requestTimeout,
      enableDebugLogging: enableDebugLogging ?? this.enableDebugLogging,
      era: era ?? this.era,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpClientConfig &&
          name == other.name &&
          version == other.version &&
          description == other.description &&
          capabilities == other.capabilities &&
          maxRetries == other.maxRetries &&
          retryDelay == other.retryDelay &&
          requestTimeout == other.requestTimeout &&
          enableDebugLogging == other.enableDebugLogging &&
          era == other.era;

  @override
  int get hashCode => Object.hash(
    name,
    version,
    description,
    capabilities,
    maxRetries,
    retryDelay,
    requestTimeout,
    enableDebugLogging,
    era,
  );

  @override
  String toString() =>
      'McpClientConfig('
      'name: $name, '
      'version: $version, '
      'description: $description, '
      'capabilities: $capabilities, '
      'maxRetries: $maxRetries, '
      'retryDelay: $retryDelay, '
      'requestTimeout: $requestTimeout, '
      'enableDebugLogging: $enableDebugLogging, '
      'era: $era)';
}

/// Configuration for transport connections
@immutable
sealed class TransportConfig {
  const TransportConfig();

  /// Configuration for STDIO transport
  const factory TransportConfig.stdio({
    required String command,
    List<String> arguments,
    String? workingDirectory,
    Map<String, String>? environment,
  }) = StdioTransportConfig;

  /// Configuration for SSE transport with all features
  const factory TransportConfig.sse({
    required String serverUrl,
    Map<String, String>? headers,
    Duration? connectionTimeout,
    Duration? heartbeatInterval,
    OAuthToken? oauthToken,
    String? bearerToken,
    bool enableCompression,
    bool enableGzip,
    bool enableDeflate,
    int compressionLevel,
    int maxMissedHeartbeats,
  }) = SseTransportConfig;

  /// Configuration for Streamable HTTP transport with all features
  const factory TransportConfig.streamableHttp({
    required String baseUrl,
    Map<String, String>? headers,
    Duration? timeout,
    int? maxConcurrentRequests,
    bool? useHttp2,
    McpOAuth? oauth,
    bool enableCompression,
    Duration? heartbeatInterval,
    int maxMissedHeartbeats,
    bool terminateOnClose,  // Whether to send DELETE on disconnect (default: true)
  }) = StreamableHttpTransportConfig;
}

@immutable
final class StdioTransportConfig extends TransportConfig {
  final String command;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;

  const StdioTransportConfig({
    required this.command,
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
  });
}

@immutable
final class SseTransportConfig extends TransportConfig {
  final String serverUrl;
  final Map<String, String>? headers;

  /// How long opening the event stream may take.
  final Duration? connectionTimeout;

  /// Ping the server at this interval once connected
  /// ([Client.startKeepAlive]); [maxMissedHeartbeats] unanswered pings in a
  /// row end the connection.
  final Duration? heartbeatInterval;

  /// A token sent as `Authorization: Bearer` (HTTP+SSE has no authorization
  /// flow of its own; use Streamable HTTP with `oauth:` for one).
  final OAuthToken? oauthToken;

  /// As [oauthToken], given as the token string.
  final String? bearerToken;

  /// No effect: responses are decompressed by the HTTP client, which asks
  /// for gzip itself. Kept so 2.x calls compile.
  @Deprecated('No effect: the HTTP client negotiates compression itself')
  final bool enableCompression;
  @Deprecated('No effect: the HTTP client negotiates compression itself')
  final bool enableGzip;
  @Deprecated('No effect: the HTTP client negotiates compression itself')
  final bool enableDeflate;
  @Deprecated('No effect: the HTTP client negotiates compression itself')
  final int compressionLevel;

  /// Unanswered heartbeat pings in a row that end the connection.
  final int maxMissedHeartbeats;

  const SseTransportConfig({
    required this.serverUrl,
    this.headers,
    this.connectionTimeout,
    this.heartbeatInterval,
    this.oauthToken,
    this.bearerToken,
    this.enableCompression = false,
    this.enableGzip = true,
    this.enableDeflate = true,
    this.compressionLevel = 6,
    this.maxMissedHeartbeats = 3,
  });
}

@immutable
final class StreamableHttpTransportConfig extends TransportConfig {
  final String baseUrl;
  final Map<String, String>? headers;
  final Duration? timeout;

  /// Requests in flight at once; more wait their turn.
  final int? maxConcurrentRequests;

  /// No effect: the HTTP client speaks HTTP/1.1. Kept so 2.x calls compile.
  @Deprecated('No effect: the HTTP client speaks HTTP/1.1')
  final bool? useHttp2;

  /// MCP authorization: discovery, registration and tokens (see [McpOAuth]).
  final McpOAuth? oauth;

  /// No effect: responses are decompressed by the HTTP client, which asks
  /// for gzip itself. Kept so 2.x calls compile.
  @Deprecated('No effect: the HTTP client negotiates compression itself')
  final bool enableCompression;

  /// Ping the server at this interval once connected, on revisions that have
  /// `ping` ([Client.startKeepAlive]); [maxMissedHeartbeats] unanswered pings
  /// in a row end the connection.
  final Duration? heartbeatInterval;

  /// Unanswered heartbeat pings in a row that end the connection.
  final int maxMissedHeartbeats;

  /// Send `DELETE` to end the session when disconnecting.
  final bool terminateOnClose;

  const StreamableHttpTransportConfig({
    required this.baseUrl,
    this.headers,
    this.timeout,
    this.maxConcurrentRequests,
    this.useHttp2,
    this.oauth,
    this.enableCompression = false,
    this.heartbeatInterval,
    this.maxMissedHeartbeats = 3,
    this.terminateOnClose = true,  // Default: true for backward compatibility
  });
}

typedef MCPClient = McpClient;

/// Modern MCP Client factory with enhanced error handling and configuration
@immutable
class McpClient {
  const McpClient._();

  /// Create a new MCP client with the specified configuration
  static Client createClient(McpClientConfig config) {
    if (config.enableDebugLogging) {
      Logger.root.level = Level.FINE;
    }

    return Client(
      name: config.name,
      version: config.version,
      description: config.description,
      capabilities: config.capabilities,
      protocolVersion: config.protocolVersion,
      requestTimeout: config.requestTimeout,
    );
  }

  /// Create and connect a client using the provided configuration
  static Future<Result<Client, Exception>> createAndConnect({
    required McpClientConfig config,
    required TransportConfig transportConfig,
  }) async {
    return Results.catchingAsync(() async {
      final client = createClient(config);
      await client.connectWithRetry(
        () => _createTransport(transportConfig),
        maxRetries: config.maxRetries,
        delay: config.retryDelay,
        era: config.era,
      );
      // Heartbeat: the specification's connection health check is `ping`
      // (none exists in 2026-07-28, which has no connection to keep).
      final (interval, maxMissed) = switch (transportConfig) {
        SseTransportConfig(:final heartbeatInterval, :final maxMissedHeartbeats) =>
          (heartbeatInterval, maxMissedHeartbeats),
        StreamableHttpTransportConfig(:final heartbeatInterval, :final maxMissedHeartbeats) =>
          (heartbeatInterval, maxMissedHeartbeats),
        StdioTransportConfig() => (null, 0),
      };
      if (interval != null && !client.isStateless) {
        client.startKeepAlive(interval, timeout: interval, maxMissed: maxMissed < 1 ? 1 : maxMissed);
      }

      return client;
    });
  }

  /// Create a transport from the given configuration
  static Future<ClientTransport> _createTransport(TransportConfig config) {
    return switch (config) {
      StdioTransportConfig(
        command: final command,
        arguments: final arguments,
        workingDirectory: final workingDirectory,
        environment: final environment,
      ) =>
        StdioClientTransport.create(
          command: command,
          arguments: arguments,
          workingDirectory: workingDirectory,
          environment: environment,
        ),
      SseTransportConfig(
        serverUrl: final serverUrl,
        headers: final headers,
        oauthToken: final oauthToken,
        bearerToken: final bearerToken,
        connectionTimeout: final connectionTimeout,
      ) =>
        _createSseTransport(
          serverUrl: serverUrl,
          headers: headers,
          token: bearerToken ?? oauthToken?.accessToken,
          connectionTimeout: connectionTimeout,
        ),
      StreamableHttpTransportConfig(
        baseUrl: final baseUrl,
        headers: final headers,
        timeout: final timeout,
        maxConcurrentRequests: final maxConcurrentRequests,
        useHttp2: final useHttp2,
        oauth: final oauth,
        enableCompression: final _,
        heartbeatInterval: final _,
        maxMissedHeartbeats: final _,
        terminateOnClose: final terminateOnClose,
      ) =>
        StreamableHttpClientTransport.create(
          baseUrl: baseUrl,
          headers: headers,
          timeout: timeout,
          maxConcurrentRequests: maxConcurrentRequests,
          useHttp2: useHttp2,
          oauth: oauth,
          terminateOnClose: terminateOnClose,
        ),
    };
  }

  /// The HTTP+SSE transport, with the bearer [token] (when given) on the
  /// stream and on every message POST.
  static Future<ClientTransport> _createSseTransport({
    required String serverUrl,
    Map<String, String>? headers,
    String? token,
    Duration? connectionTimeout,
  }) {
    final opening = SseClientTransport.create(
      serverUrl: serverUrl,
      headers: {
        ...?headers,
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );
    return connectionTimeout == null ? opening : opening.timeout(connectionTimeout);
  }

  /// Create a stdio transport with the given configuration
  static Future<Result<StdioClientTransport, Exception>> createStdioTransport({
    required String command,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Results.catchingAsync(
      () => StdioClientTransport.create(
        command: command,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      ),
    );
  }

  /// Create an SSE transport with the given configuration
  static Future<Result<SseClientTransport, Exception>> createSseTransport({
    required String serverUrl,
    Map<String, String>? headers,
  }) {
    return Results.catchingAsync(
      () => SseClientTransport.create(serverUrl: serverUrl, headers: headers),
    );
  }

  /// Create a Streamable HTTP transport with the given configuration
  static Future<Result<StreamableHttpClientTransport, Exception>>
  createStreamableHttpTransport({
    required String baseUrl,
    Map<String, String>? headers,
    Duration? timeout,
    int? maxConcurrentRequests,
    bool? useHttp2,
  }) {
    return Results.catchingAsync(
      () => StreamableHttpClientTransport.create(
        baseUrl: baseUrl,
        headers: headers,
        timeout: timeout,
        maxConcurrentRequests: maxConcurrentRequests,
        useHttp2: useHttp2,
      ),
    );
  }

  /// Helper method to create a simple client configuration
  static McpClientConfig simpleConfig({
    required String name,
    required String version,
    String? description,
    bool enableDebugLogging = false,
  }) {
    return McpClientConfig(
      name: name,
      version: version,
      description: description,
      enableDebugLogging: enableDebugLogging,
    );
  }

  /// Helper method to create a production-ready client configuration
  static McpClientConfig productionConfig({
    required String name,
    required String version,
    String? description,
    ClientCapabilities? capabilities,
  }) {
    return McpClientConfig(
      name: name,
      version: version,
      description: description,
      capabilities: capabilities ?? const ClientCapabilities(),
      maxRetries: 5,
      retryDelay: const Duration(seconds: 1),
      requestTimeout: const Duration(seconds: 60),
      enableDebugLogging: false,
    );
  }
}
