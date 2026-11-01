/// Transports that require `dart:io`, absent on the web.
///
/// The web branch keeps the same type names and constructor signatures as
/// [transport_io.dart] so shared code compiles unchanged. Constructing one
/// here fails loudly: an unsupported capability is reported, never silently
/// substituted with something that looks like it worked.
library;

import 'dart:async';

import '../models/models.dart';
import 'client_transport.dart';

const String _unsupported =
    'This transport requires dart:io and is unavailable on this platform. '
    'Use StreamableHttpClientTransport instead.';

/// Process-backed STDIO transport. Native platforms only.
class StdioClientTransport implements ClientTransport, TransportClosureReason {
  StdioClientTransport._();

  /// Always throws on this platform — there is no process to spawn.
  static Future<StdioClientTransport> create({
    required String command,
    List<String> arguments = const [],
    String? workingDirectory,
    Map<String, String>? environment,
    bool runInShell = false,
  }) async {
    throw McpError('STDIO transport: $_unsupported');
  }

  /// There is no process on this platform.
  Stream<String> get stderr => const Stream<String>.empty();

  /// There is no process on this platform.
  int? get exitCode => null;

  @override
  String? get closeReason => null;

  @override
  Stream<dynamic> get onMessage => throw McpError('STDIO transport: $_unsupported');

  @override
  Future<void> get onClose => throw McpError('STDIO transport: $_unsupported');

  @override
  void send(dynamic message) =>
      throw McpError('STDIO transport: $_unsupported');

  @override
  void close() {}
}

/// Legacy SSE transport built on `dart:io` HTTP types. Native platforms only.
class SseClientTransport implements ClientTransport {
  SseClientTransport._();

  /// Always throws on this platform.
  static Future<SseClientTransport> create({
    required String serverUrl,
    Map<String, String>? headers,
  }) async {
    throw McpError('Legacy SSE transport: $_unsupported');
  }

  @override
  Stream<dynamic> get onMessage =>
      throw McpError('Legacy SSE transport: $_unsupported');

  @override
  Future<void> get onClose =>
      throw McpError('Legacy SSE transport: $_unsupported');

  @override
  void send(dynamic message) =>
      throw McpError('Legacy SSE transport: $_unsupported');

  @override
  void close() {}
}
