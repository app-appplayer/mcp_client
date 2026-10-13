/// `DelegatingClient` hands every call to the client it wraps, so a wrapper
/// overrides only what it changes; and `connect(statelessMode:)` keeps the
/// 2.x form working.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// Answers initialize, tools/list and tools/call; records what was sent.
class _Server implements ClientTransport {
  final _incoming = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<dynamic> get onMessage => _incoming.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final m = Map<String, dynamic>.from(message as Map);
    sent.add(m);
    final id = m['id'];
    if (id == null) return;
    final Object result = switch (m['method']) {
      'initialize' => {
          'protocolVersion': McpProtocol.v2025_11_25,
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {'tools': {}},
        },
      'tools/list' => {
          'tools': [
            {'name': 'echo', 'inputSchema': {'type': 'object'}},
          ],
        },
      'tools/call' => {
          'content': [
            {'type': 'text', 'text': 'called ${(m['params'] as Map)['name']}'},
          ],
        },
      _ => <String, dynamic>{},
    };
    scheduleMicrotask(() => _incoming.add({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _incoming.close();
  }
}

class _Counting extends DelegatingClient {
  _Counting(super.inner);
  int calls = 0;

  @override
  Future<CallToolResult> callTool(String name, Map<String, dynamic> toolArguments,
      {Map<String, dynamic>? meta, RequestOptions? options}) {
    calls++;
    return super.callTool(name, toolArguments, meta: meta, options: options);
  }
}

void main() {
  test('a wrapper overrides one member; every other call reaches the inner client', () async {
    final inner = Client(name: 'c', version: '1');
    final Client client = _Counting(inner);
    final server = _Server();
    await client.connect(server, era: ProtocolEra.legacy);

    expect(client.isConnected, isTrue);
    expect(client.negotiatedProtocolVersion, McpProtocol.v2025_11_25);
    expect((await client.listTools()).single.name, 'echo');
    final result = await client.callTool('echo', {});
    expect((result.content.single as TextContent).text, 'called echo');
    expect((client as _Counting).calls, 1);
    expect(server.sent.map((m) => m['method']), containsAll(['initialize', 'tools/list', 'tools/call']));

    client.disconnect();
    expect(inner.isConnected, isFalse);
  });

  group('connect(statelessMode:) — the 2.x form', () {
    test('false is the initialize handshake', () async {
      final client = Client(name: 'c', version: '1');
      final server = _Server();
      // ignore: deprecated_member_use
      await client.connect(server, statelessMode: false);
      expect(client.era, ProtocolEra.legacy);
      expect(server.sent.first['method'], 'initialize');
      client.disconnect();
    });

    test('true is 2026-07-28, without a handshake', () async {
      final client = Client(name: 'c', version: '1');
      final server = _Server();
      // ignore: deprecated_member_use
      await client.connect(server, statelessMode: true);
      expect(client.era, ProtocolEra.modern);
      expect(server.sent.where((m) => m['method'] == 'initialize'), isEmpty);
      client.disconnect();
    });

    test('with era as well is a mistake', () {
      final client = Client(name: 'c', version: '1');
      expect(
          // ignore: deprecated_member_use
          () => client.connect(_Server(), era: ProtocolEra.modern, statelessMode: true),
          throwsArgumentError);
    });
  });
}
