/// 2.x names that 3.0 consumers still use both as constructors and as
/// types: `ResourceContentInfo`, `ResourceContent`, `Message`.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

// As types, the way 2.x code wrote them.
List<ResourceContentInfo> _contents() => [
      ResourceContentInfo(uri: 'file:///a', text: 'hi', mimeType: 'text/plain'),
      ResourceContentInfo(uri: 'file:///b', blob: 'AAAA'),
    ];
Message _template = Message(role: 'user', content: TextContent(text: 'hello'));
ResourceContent _embedded = ResourceContent(uri: 'file:///c', text: 'x');

void main() {
  test('values are the protocol types themselves, with the 2.x shapes', () {
    final c = _contents();
    expect(c[0], isA<TextResourceContents>());
    expect(c[1], isA<BlobResourceContents>());
    expect(c[0].toJson(), {'uri': 'file:///a', 'mimeType': 'text/plain', 'text': 'hi'});
    expect(ReadResourceResult(contents: c).check(), isEmpty);
    expect(_template.role, Role.user);
    expect(_template.toJson(), {'role': 'user', 'content': {'type': 'text', 'text': 'hello'}});
    final PromptMessage asProtocol = _template;
    expect(asProtocol.toJson()['role'], 'user');
    expect(_embedded.toJson(), {'type': 'resource', 'resource': {'uri': 'file:///c', 'text': 'x'}});
  });

  test('without text or blob, text stays null as in 2.x (no invented empty string)', () {
    final c = ResourceContentInfo(uri: 'file:///x', mimeType: 'application/json');
    expect(c.text, isNull);
    expect(c.toJson(), {'uri': 'file:///x', 'mimeType': 'application/json'});
  });
}
