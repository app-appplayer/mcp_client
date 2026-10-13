/// Legacy SSE transports on platforms without `dart:io`.
///
/// The auth / compressed / heartbeat SSE variants are built on `dart:io` HTTP
/// types down to their field declarations, so they cannot compile for the web.
/// This branch keeps the same names and constructor signatures so shared code
/// compiles, and fails loudly on construction — an unsupported capability is
/// reported, never silently substituted.
///
/// Value types (config, stats, enums) are declared here as well. They carry no
/// platform dependency; they are duplicated rather than shared because the two
/// branches never coexist in one compilation.
library;

import 'dart:async';

import '../auth/oauth.dart';
import '../models/models.dart';
import 'client_transport.dart';

const String _unsupported =
    'Legacy SSE transports require dart:io and are unavailable on this '
    'platform. Use StreamableHttpClientTransport instead.';

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// Content encodings the compressed SSE transport can negotiate.
enum CompressionType {
  none('identity'),
  gzip('gzip'),
  deflate('deflate'),
  brotli('br');

  const CompressionType(this.encoding);

  final String encoding;
}

/// Connection health as judged by the heartbeat transport.
enum ConnectionHealth { healthy, degraded, unhealthy, disconnected }

/// Heartbeat configuration.
class HeartbeatConfig {
  /// Interval between heartbeat checks
  final Duration interval;

  /// Timeout for heartbeat response
  final Duration timeout;

  /// Number of missed heartbeats before marking connection as unhealthy
  final int maxMissedBeats;

  /// Whether to automatically reconnect on connection failure
  final bool autoReconnect;

  /// Maximum number of reconnection attempts
  final int maxReconnectAttempts;

  /// Delay between reconnection attempts
  final Duration reconnectDelay;

  const HeartbeatConfig({
    this.interval = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 10),
    this.maxMissedBeats = 3,
    this.autoReconnect = true,
    this.maxReconnectAttempts = 5,
    this.reconnectDelay = const Duration(seconds: 5),
  });
}

/// Heartbeat statistics.
class HeartbeatStats {
  final int totalHeartbeats;
  final int missedHeartbeats;
  final int reconnectionAttempts;
  final Duration averageLatency;
  final ConnectionHealth currentHealth;
  final DateTime? lastHeartbeat;
  final DateTime? lastMissedHeartbeat;

  const HeartbeatStats({
    required this.totalHeartbeats,
    required this.missedHeartbeats,
    required this.reconnectionAttempts,
    required this.averageLatency,
    required this.currentHealth,
    this.lastHeartbeat,
    this.lastMissedHeartbeat,
  });

  Map<String, dynamic> toJson() => {
    'totalHeartbeats': totalHeartbeats,
    'missedHeartbeats': missedHeartbeats,
    'reconnectionAttempts': reconnectionAttempts,
    'averageLatencyMs': averageLatency.inMilliseconds,
    'currentHealth': currentHealth.name,
    'lastHeartbeat': lastHeartbeat?.toIso8601String(),
    'lastMissedHeartbeat': lastMissedHeartbeat?.toIso8601String(),
    'successRate':
        totalHeartbeats > 0
            ? (totalHeartbeats - missedHeartbeats) / totalHeartbeats
            : 0.0,
  };
}

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

/// OAuth-aware legacy SSE transport. Native platforms only.
@Deprecated('Use SseClientTransport with an Authorization header (TransportConfig.sse(bearerToken:)); this transport\'s event parsing is not the standard one')
class SseAuthClientTransport implements ClientTransport {
  SseAuthClientTransport._();

  /// Always throws on this platform.
  static Future<SseAuthClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    OAuthToken? oauthToken,
    OAuthClient? oauthClient,
    String? bearerToken,
  }) async {
    throw McpError(_unsupported);
  }

  @override
  Stream<dynamic> get onMessage => throw McpError(_unsupported);

  @override
  Future<void> get onClose => throw McpError(_unsupported);

  @override
  void send(dynamic message) => throw McpError(_unsupported);

  @override
  void close() {}
}

/// Compression-negotiating legacy SSE transport. Native platforms only.
@Deprecated('Use SseClientTransport: the HTTP client negotiates compression itself')
class SseCompressedClientTransport implements ClientTransport {
  SseCompressedClientTransport._();

  /// Always throws on this platform.
  static Future<SseCompressedClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    List<CompressionType>? supportedCompressions,
    int compressionThreshold = 1024,
  }) async {
    throw McpError(_unsupported);
  }

  @override
  Stream<dynamic> get onMessage => throw McpError(_unsupported);

  @override
  Future<void> get onClose => throw McpError(_unsupported);

  @override
  void send(dynamic message) => throw McpError(_unsupported);

  @override
  void close() {}
}

/// Heartbeat-monitoring legacy SSE transport. Native platforms only.
@Deprecated('Use SseClientTransport and Client.startKeepAlive (TransportConfig.sse(heartbeatInterval:)); this transport waits for heartbeat events no MCP server sends')
class SseHeartbeatClientTransport implements ClientTransport {
  SseHeartbeatClientTransport._();

  /// Always throws on this platform.
  static Future<SseHeartbeatClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
    HeartbeatConfig? heartbeatConfig,
  }) async {
    throw McpError(_unsupported);
  }

  @override
  Stream<dynamic> get onMessage => throw McpError(_unsupported);

  @override
  Future<void> get onClose => throw McpError(_unsupported);

  @override
  void send(dynamic message) => throw McpError(_unsupported);

  @override
  void close() {}
}
