/// Transport contract shared by every client transport implementation.
///
/// Kept free of platform imports so both the native and web branches of
/// `transport.dart` implement the same type.
library;

/// Abstract base class for client transport implementations
abstract class ClientTransport {
  /// Stream of incoming messages
  Stream<dynamic> get onMessage;

  /// Future that completes when the transport is closed
  Future<void> get onClose;

  /// Send a message through the transport
  void send(dynamic message);

  /// Close the transport
  void close();
}

/// A transport that can say why its connection ended.
///
/// A client puts the reason into the error of every request the end leaves
/// unanswered, so the caller learns more than "disconnected" — for a server
/// process, with what code it exited and what it wrote to its standard error.
abstract interface class TransportClosureReason {
  /// Why the connection ended; null while it is open or when unknown.
  String? get closeReason;
}
