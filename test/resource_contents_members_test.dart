/// `ResourceContents` exposes `uri` / `mimeType` / `text` / `blob` as members
/// of the type itself, so a library reading a result it did not import the
/// types for still compiles and reads them (an extension would not be in
/// scope there).
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'support/reads_contents_without_import.dart';

String _typed(ReadResourceResult r) => r.contents.first.text!;

void main() {
  test('common fields on every kind, typed and untyped', () {
    final r = ReadResourceResult.fromJson({
      'contents': [
        {'uri': 'file:///a.txt', 'mimeType': 'text/plain', 'text': 'hello'},
        {'uri': 'file:///b.bin', 'blob': 'AAAA'},
        {'uri': 'x://future', 'something': 1},
      ],
    });
    expect(_typed(r), 'hello');
    expect(firstText(r), 'hello');
    final [text, blob, unknown] = r.contents;
    expect((text.uri, text.mimeType, text.text, text.blob), ('file:///a.txt', 'text/plain', 'hello', null));
    expect((blob.uri, blob.mimeType, blob.text, blob.blob), ('file:///b.bin', null, null, 'AAAA'));
    expect((unknown.uri, unknown.text), ('x://future', null));
  });
}
