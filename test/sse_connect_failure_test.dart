/// A connection that fails must fail for the caller, once, and leave nothing
/// behind: no error may escape to the zone where nobody can catch it (in a
/// plain Dart program that ends the process).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  Future<void> expectCleanFailure(Future<HttpServer> Function() serverFor, String Function(int port) url) async {
    final server = await serverFor();
    addTearDown(() => server.close(force: true));
    final escaped = <Object>[];
    Object? failure;
    await runZonedGuarded(() async {
      try {
        await SseClientTransport.create(serverUrl: url(server.port));
      } catch (e) {
        failure = e;
      }
      // give a stray asynchronous error the time to surface
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }, (error, stack) => escaped.add(error));
    expect(failure, isA<McpError>(), reason: 'the caller is told');
    expect(escaped, isEmpty, reason: 'and nothing else escapes: $escaped');
  }

  test('a server that refuses the stream (401) fails the caller and leaks no error', () async {
    await expectCleanFailure(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 401;
        request.response.write('{"error":"bad token"}');
        await request.response.close();
      });
      return server;
    }, (port) => 'http://127.0.0.1:$port/sse');
  });

  test('a port nobody listens on fails the caller and leaks no error', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final escaped = <Object>[];
    Object? failure;
    await runZonedGuarded(() async {
      try {
        await SseClientTransport.create(serverUrl: 'http://127.0.0.1:$port/sse');
      } catch (e) {
        failure = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }, (error, stack) => escaped.add(error));
    expect(failure, isA<McpError>());
    expect(escaped, isEmpty, reason: 'nothing else escapes: $escaped');
  });
}
