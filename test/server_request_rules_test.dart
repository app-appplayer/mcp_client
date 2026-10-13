/// What the client answers to server requests (client/sampling, client/roots,
/// client/elicitation): nothing it did not declare, nothing that breaks the
/// message rules, and -1 when the user declines a sampling request.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  Future<(Client, MockTransport)> connect(ClientCapabilities caps) async {
    final transport = MockTransport()
      ..queueResponse({
        'jsonrpc': '2.0',
        'result': {
          'protocolVersion': '2025-11-25',
          'serverInfo': {'name': 's', 'version': '1'},
          'capabilities': <String, dynamic>{},
        },
      });
    final client = Client(name: 'c', version: '1', capabilities: caps);
    client.onSamplingRequest((p) async => CreateMessageResult(
          role: Role.assistant,
          content: [TextContent(text: 'ok')],
          model: 'm',
        ));
    client.onElicitationRequestTyped((p) async => ElicitResult(action: ElicitResultAction.decline));
    await client.connect(transport, era: ProtocolEra.legacy);
    addTearDown(client.disconnect);
    return (client, transport);
  }

  var next = 0;
  Future<Map> ask(MockTransport t, String method, Map<String, dynamic> params) async {
    final id = 'srv-${++next}';
    t.simulateMessage({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    await _settle();
    return t.sentMessages.lastWhere((m) => m['id'] == id);
  }

  final hello = {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}};

  test('undeclared capabilities are Method not found', () async {
    final (_, t) = await connect(const ClientCapabilities());
    expect((await ask(t, 'sampling/createMessage', {'messages': [hello], 'maxTokens': 1}))['error']['code'], -32601);
    expect((await ask(t, 'roots/list', {}))['error']['code'], -32601);
    expect((await ask(t, 'elicitation/create', {'message': 'x', 'requestedSchema': {'type': 'object', 'properties': {}}}))['error']['code'], -32601);
  });

  test('tool use without sampling.tools is Invalid params', () async {
    final (_, t) = await connect(const ClientCapabilities(sampling: true));
    final r = await ask(t, 'sampling/createMessage', {'messages': [hello], 'maxTokens': 1, 'tools': []});
    expect(r['error']['code'], -32602);
  });

  test('mixed tool results are Invalid params', () async {
    final (_, t) = await connect(const ClientCapabilities(sampling: true, samplingTools: true));
    final r = await ask(t, 'sampling/createMessage', {
      'messages': [
        hello,
        {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'c1', 'name': 'w', 'input': <String, dynamic>{}}]},
        {'role': 'user', 'content': [
          {'type': 'text', 'text': 'here'},
          {'type': 'tool_result', 'toolUseId': 'c1', 'content': []},
        ]},
      ],
      'maxTokens': 1,
      'tools': [],
    });
    expect(r['error']['code'], -32602);
  });

  test('a declined sampling request is error -1', () async {
    final (client, t) = await connect(const ClientCapabilities(sampling: true));
    client.onSamplingRequest((p) async => throw const McpUserRejected());
    final r = await ask(t, 'sampling/createMessage', {'messages': [hello], 'maxTokens': 1});
    expect(r['error'], {'code': -1, 'message': 'User rejected sampling request'});
  });

  test('elicitation modes follow the declared capability; no mode means form', () async {
    final (_, urlOnly) = await connect(const ClientCapabilities(elicitationUrl: true));
    final form = {'message': 'x', 'requestedSchema': {'type': 'object', 'properties': {}}};
    expect((await ask(urlOnly, 'elicitation/create', form))['error']['code'], -32602);

    final (_, bare) = await connect(const ClientCapabilities(elicitation: true));
    expect((await ask(bare, 'elicitation/create', form))['result']['action'], 'decline');
    final url = {'mode': 'url', 'message': 'x', 'url': 'https://example.com', 'elicitationId': 'e1'};
    expect((await ask(bare, 'elicitation/create', url))['error']['code'], -32602);
  });

  group('elicitation', () {
    final form = {
      'message': 'Your name?',
      'requestedSchema': {
        'type': 'object',
        'properties': {'name': {'type': 'string', 'minLength': 2}},
        'required': ['name'],
      },
    };

    test('accepted form content must match the requested schema', () async {
      final (client, t) = await connect(const ClientCapabilities(elicitation: true));
      client.onElicitationRequestTyped((p) async => ElicitResult(action: ElicitResultAction.accept, content: {'name': 'A'}));
      expect((await ask(t, 'elicitation/create', form))['error']['code'], -32603);
      client.onElicitationRequestTyped((p) async => ElicitResult(action: ElicitResultAction.accept, content: {'name': 'Ana'}));
      expect((await ask(t, 'elicitation/create', form))['result']['content'], {'name': 'Ana'});
    });

    test('a URL request without a valid url or elicitationId is Invalid params', () async {
      final (_, t) = await connect(const ClientCapabilities(elicitationUrl: true));
      expect((await ask(t, 'elicitation/create', {'mode': 'url', 'message': 'x', 'url': 'not a url', 'elicitationId': 'e'}))['error']['code'], -32602);
      expect((await ask(t, 'elicitation/create', {'mode': 'url', 'message': 'x', 'url': 'https://example.com'}))['error']['code'], -32602);
    });

    test('completion notices only for accepted, still-open URL elicitations', () async {
      final (client, t) = await connect(const ClientCapabilities(elicitationUrl: true));
      client.onElicitationRequestTyped((p) async => ElicitResult(action: ElicitResultAction.accept));
      final seen = <String>[];
      final sub = client.onElicitationComplete.listen(seen.add);
      await ask(t, 'elicitation/create', {'mode': 'url', 'message': 'x', 'url': 'https://example.com/a', 'elicitationId': 'e1'});
      for (final id in ['unknown', 'e1', 'e1']) {
        t.simulateMessage({'jsonrpc': '2.0', 'method': 'notifications/elicitation/complete', 'params': {'elicitationId': id}});
      }
      await _settle();
      expect(seen, ['e1']);
      await sub.cancel();
    });
  });

  group('roots', () {
    test('only file:// roots without .. segments', () async {
      final (client, _) = await connect(const ClientCapabilities(roots: true));
      expect(() => client.addRoot(Root(uri: 'https://example.com', name: 'web')), throwsArgumentError);
      expect(() => client.addRoot(Root(uri: 'file:///home/u/../etc', name: 'up')), throwsArgumentError);
      client.addRoot(Root(uri: 'file:///home/u/project', name: 'project'));
    });

    test('list_changed only when roots.listChanged is declared', () async {
      final (quiet, t1) = await connect(const ClientCapabilities(roots: true));
      quiet.addRoot(Root(uri: 'file:///a', name: 'a'));
      expect(t1.sentMessages.where((m) => m['method'] == 'notifications/roots/list_changed'), isEmpty);

      final (loud, t2) = await connect(const ClientCapabilities(roots: true, rootsListChanged: true));
      loud.addRoot(Root(uri: 'file:///a', name: 'a'));
      expect(t2.sentMessages.where((m) => m['method'] == 'notifications/roots/list_changed'), hasLength(1));
    });

    test('roots/list answers the registered roots', () async {
      final (client, t) = await connect(const ClientCapabilities(roots: true));
      client.addRoot(Root(uri: 'file:///a', name: 'a'));
      final r = await ask(t, 'roots/list', {});
      expect(r['result']['roots'], [{'uri': 'file:///a', 'name': 'a'}]);
    });
  });
}
