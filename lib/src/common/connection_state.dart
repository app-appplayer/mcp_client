import 'package:meta/meta.dart';
import '../models/models.dart';

/// Represents the various states of an MCP connection
@immutable
sealed class ConnectionState {
  const ConnectionState();

  /// The connection is disconnected
  const factory ConnectionState.disconnected() = Disconnected;

  /// The connection is in the process of connecting
  const factory ConnectionState.connecting() = Connecting;

  /// The connection is established and ready
  const factory ConnectionState.connected(ServerInfo serverInfo) = Connected;

  /// The connection is in the process of disconnecting
  const factory ConnectionState.disconnecting() = Disconnecting;

  /// The connection has failed with an error
  const factory ConnectionState.error(Object error, StackTrace? stackTrace) =
      ConnectionError;

  /// Returns true if the connection is ready for use
  bool get isConnected => switch (this) {
    Connected() => true,
    _ => false,
  };

  /// Returns true if the connection is in a transitional state
  bool get isTransitioning => switch (this) {
    Connecting() || Disconnecting() => true,
    _ => false,
  };

  /// Returns true if the connection has an error
  bool get hasError => switch (this) {
    ConnectionError() => true,
    _ => false,
  };

  /// Returns the server info if connected, null otherwise
  ServerInfo? get serverInfo => switch (this) {
    Connected(serverInfo: final info) => info,
    _ => null,
  };

  /// Returns the error if in error state, null otherwise
  Object? get error => switch (this) {
    ConnectionError(error: final error) => error,
    _ => null,
  };

  /// Maps the state to a value using the provided functions
  T map<T>({
    required T Function() onDisconnected,
    required T Function() onConnecting,
    required T Function(ServerInfo serverInfo) onConnected,
    required T Function() onDisconnecting,
    required T Function(Object error, StackTrace? stackTrace) onError,
  }) => switch (this) {
    Disconnected() => onDisconnected(),
    Connecting() => onConnecting(),
    Connected(serverInfo: final info) => onConnected(info),
    Disconnecting() => onDisconnecting(),
    ConnectionError(error: final error, stackTrace: final stackTrace) =>
      onError(error, stackTrace),
  };
}

/// The connection is disconnected
@immutable
final class Disconnected extends ConnectionState {
  const Disconnected();

  @override
  bool operator ==(Object other) => other is Disconnected;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'ConnectionState.disconnected()';
}

/// The connection is in the process of connecting
@immutable
final class Connecting extends ConnectionState {
  const Connecting();

  @override
  bool operator ==(Object other) => other is Connecting;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'ConnectionState.connecting()';
}

/// The connection is established and ready
@immutable
final class Connected extends ConnectionState {
  /// Information about the connected server
  @override
  final ServerInfo serverInfo;

  const Connected(this.serverInfo);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Connected && serverInfo == other.serverInfo;

  @override
  int get hashCode => serverInfo.hashCode;

  @override
  String toString() => 'ConnectionState.connected($serverInfo)';
}

/// The connection is in the process of disconnecting
@immutable
final class Disconnecting extends ConnectionState {
  const Disconnecting();

  @override
  bool operator ==(Object other) => other is Disconnecting;

  @override
  int get hashCode => 3;

  @override
  String toString() => 'ConnectionState.disconnecting()';
}

/// The connection has failed with an error
@immutable
final class ConnectionError extends ConnectionState {
  /// The error that occurred
  @override
  final Object error;

  /// The stack trace associated with the error
  final StackTrace? stackTrace;

  const ConnectionError(this.error, this.stackTrace);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionError &&
          error == other.error &&
          stackTrace == other.stackTrace;

  @override
  int get hashCode => Object.hash(error, stackTrace);

  @override
  String toString() =>
      'ConnectionState.error($error${stackTrace != null ? ', $stackTrace' : ''})';
}
