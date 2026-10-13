/// Defects found re-checking 3.0 against 2.x and the specification: the 2.x
/// members restored, the listen failure path, and generated readers that
/// never invent a value.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

class _ScriptedTransport implements ClientTransport {
  final _incoming = StreamController<dynamic>.broadcast();
  final _closed = Completer<void>();
  final List<Map<String, dynamic>> sent = [];
  final List<dynamic> Function(Map<String, dynamic> out) responder;

  _ScriptedTransport(this.responder);

  @override
  Stream<dynamic> get onMessage => _incoming.stream;

  @override
  Future<void> get onClose => _closed.future;

  @override
  void send(dynamic message) {
    final map = Map<String, dynamic>.from(message as Map);
    sent.add(map);
    scheduleMicrotask(() {
      for (final reply in responder(map)) {
        if (!_incoming.isClosed) _incoming.add(reply);
      }
    });
  }

  @override
  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _incoming.close();
  }
}

void main() {
  group('2.x members', () {
    test('onProgress keeps the 2.x handler shape and reads the spec fields', () async {
      final transport = MockTransport();
      transport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': {},
        },
      });
      final client = Client(name: 'c', version: '1');
      final got = Completer<List<Object>>();
      client.onProgress((token, progress, message) => got.complete([token, progress, message]));
      await client.connect(transport, era: ProtocolEra.legacy);
      transport.sendMockNotification({
        'jsonrpc': '2.0',
        'method': McpProtocol.methodProgress,
        // An integer token and an integer progress, no message: all spec-valid.
        'params': {'progressToken': 7, 'progress': 3},
      });
      expect(await got.future.timeout(const Duration(seconds: 2)), ['7', 3.0, '']);
      client.disconnect();
    });

    test('ResourceContent reads like 2.x: flat members and a map of annotations', () {
      final c = ResourceContent(
          uri: 'file:///a.txt', text: 'hi', mimeType: 'text/plain', annotations: {'priority': 0.5});
      expect(c.uri, 'file:///a.txt');
      expect(c.text, 'hi');
      expect(c.blob, isNull);
      expect(c.mimeType, 'text/plain');
      expect(c.annotations, {'priority': 0.5});
      expect(c.toJson(), {
        'type': 'resource',
        'resource': {'uri': 'file:///a.txt', 'mimeType': 'text/plain', 'text': 'hi'},
        'annotations': {'priority': 0.5},
      });
    });

    test('ResourceContent.fromJson reads the nested and the 2.x flat form alike', () {
      final nested = ResourceContent.fromJson({
        'type': 'resource',
        'resource': {'uri': 'x:1', 'blob': 'AA=='},
      });
      final flat = ResourceContent.fromJson({'type': 'resource', 'uri': 'x:1', 'blob': 'AA=='});
      expect(flat.toJson(), nested.toJson());
      expect(flat.blob, 'AA==');
    });

    test('ImageContent.fromBase64, TaskStatus.wire / fromWire, Task.isTerminal', () {
      final image = ImageContent.fromBase64(data: 'AA==', mimeType: 'image/png');
      expect(image.toJson(), {'type': 'image', 'data': 'AA==', 'mimeType': 'image/png'});
      expect(TaskStatus.inputRequired.wire, 'input_required');
      expect(TaskStatus.fromWire('completed'), TaskStatus.completed);
      expect(() => TaskStatus.fromWire('paused'), throwsArgumentError);
      Task task(TaskStatus s) => Task(
          taskId: 't', status: s, createdAt: '2026-01-01T00:00:00Z', lastUpdatedAt: '2026-01-01T00:00:00Z', ttl: null);
      expect(task(TaskStatus.failed).isTerminal, isTrue);
      expect(task(TaskStatus.working).isTerminal, isFalse);
    });
  });

  test('a resource whose listen stream fails to open is not kept subscribed', () async {
    final listens = <List<String>>[];
    final transport = _ScriptedTransport((out) {
      if (out['method'] != 'subscriptions/listen') return const [];
      final filter = ((out['params'] as Map)['notifications'] as Map)['resourceSubscriptions'] as List;
      final uris = filter.cast<String>();
      listens.add(uris);
      if (uris.contains('x:bad')) {
        return [
          {'jsonrpc': '2.0', 'id': out['id'], 'error': {'code': -32603, 'message': 'no'}},
        ];
      }
      return [
        {
          'jsonrpc': '2.0',
          'method': 'notifications/subscriptions/acknowledged',
          'params': {
            'notifications': {'resourceSubscriptions': uris},
            '_meta': {'io.modelcontextprotocol/subscriptionId': out['id']},
          },
        },
      ];
    });
    final client = Client(name: 'c', version: '1');
    await client.connect(transport, era: ProtocolEra.modern);
    await client.subscribeResource('x:a');
    await expectLater(client.subscribeResource('x:bad'), throwsA(isA<McpError>()));
    await client.subscribeResource('x:c');
    expect(listens.last, ['x:a', 'x:c']);
    client.disconnect();
  });

  test('ClientCapabilities read from JSON writes back what it does not name', () {
    final json = {
      'sampling': {
        'context': {'depth': 2},
        'tools': <String, dynamic>{},
      },
      'elicitation': {
        'url': {'mode': 'x'},
      },
      'roots': {'listChanged': true},
      'futureCapability': {'on': true},
    };
    expect(ClientCapabilities.fromJson(json).toJson(), json);
  });

  group('generated readers never invent a value', () {
    test('contents of an unknown kind without a uri fail to read it', () {
      final unknown = ResourceContents.fromJson({'mimeType': 'text/plain'});
      expect(() => unknown.uri, throwsFormatException);
      expect(unknown.text, isNull);
    });

    test('a member a kind does not define, with the wrong type, fails to read', () {
      final blob = ResourceContents.fromJson({'uri': 'x:1', 'blob': 'AA==', 'text': 5});
      expect(() => blob.text, throwsFormatException);
    });
  });
}
