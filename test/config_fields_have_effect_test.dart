/// A setting a class accepts must do something. A field that is stored and
/// never read looks like a promise (`maxConnections: 100`) and is not one; this
/// scans the configuration classes and fails for a field nothing reads.
///
/// A field that has no effect says so with `@Deprecated`, and is skipped.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// The `final` fields declared in class [name] of [source], with whether each
/// is deprecated.
Map<String, bool> _fields(String source, String name) {
  final start = RegExp('(class|final class) $name\\b').firstMatch(source);
  if (start == null) fail('class $name not found');
  var depth = 0, i = source.indexOf('{', start.end);
  final bodyStart = i;
  for (; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) break;
  }
  final body = source.substring(bodyStart, i);
  final out = <String, bool>{};
  final field = RegExp(r'((?:@Deprecated\([^;]*?\)\s*)?)final\s+[\w<>?,\s().]+?\s+(\w+);', multiLine: true);
  for (final m in field.allMatches(body)) {
    out[m.group(2)!] = m.group(1)!.isNotEmpty;
  }
  return out;
}

String _body(String source, String name) {
  final start = RegExp('(class|final class) $name\\b').firstMatch(source)!;
  var depth = 0, i = source.indexOf('{', start.end);
  final bodyStart = i;
  for (; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) break;
  }
  return source.substring(bodyStart, i);
}

/// [body] without the members that only repeat every field: `copyWith`,
/// `==`, `hashCode`, `toString`. Reading a field there is not using it.
String _withoutBoilerplate(String body) {
  var out = body;
  for (final signature in [
    RegExp(r'\w+\s+copyWith\('),
    RegExp(r'bool\s+operator\s*==\s*\('),
    RegExp(r'int\s+get\s+hashCode'),
    RegExp(r'String\s+toString\s*\('),
  ]) {
    final m = signature.firstMatch(out);
    if (m == null) continue;
    var i = m.end, parens = 1;
    // skip the parameter list if the signature opened one
    if (out[m.end - 1] == '(') {
      for (; i < out.length && parens > 0; i++) {
        if (out[i] == '(') parens++;
        if (out[i] == ')') parens--;
      }
    }
    // the body: `{ ... }` or `=> ... ;`
    while (i < out.length && out[i] != '{' && out[i] != '=' ) {
      i++;
    }
    var end = i;
    if (out[i] == '{') {
      var depth = 0;
      for (; end < out.length; end++) {
        if (out[end] == '{') depth++;
        if (out[end] == '}' && --depth == 0) break;
      }
    } else {
      var p = 0;
      for (; end < out.length; end++) {
        if (out[end] == '(' || out[end] == '[' || out[end] == '{') p++;
        if (out[end] == ')' || out[end] == ']' || out[end] == '}') p--;
        if (out[end] == ';' && p == 0) break;
      }
    }
    out = out.substring(0, m.start) + out.substring(end + 1);
  }
  return out;
}

String _allLibSource() => [
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart') && !f.path.endsWith('schema.g.dart')) f.readAsStringSync(),
].join('\n');

void main() {
  final lib = _allLibSource();

  void check(String file, String className) {
    test('every field of $className is read somewhere', () {
      final source = File(file).readAsStringSync();
      final fields = _fields(source, className);
      expect(fields, isNotEmpty);
      final body = _withoutBoilerplate(_body(source, className));
      final ignored = <String>[];
      fields.forEach((name, deprecated) {
        if (deprecated) return;
        // read from outside: `x.name` (not the field's own `this.name`/`other.name`)
        // (a field is also read by a destructuring pattern: `Config(name: final x)`)
        final outside = RegExp('(?<!this)(?<!other)\\.$name\\b').allMatches(lib).length +
            RegExp('\\b$name\\s*:\\s*(final|var)\\b').allMatches(lib).length;
        // read from inside its class: the bare name used again after its
        // declaration (constructor parameters are `this.name`, not bare)
        final inside = RegExp('(?<![.\\w])$name\\b').allMatches(body).length - 1;
        if (outside == 0 && inside <= 0) ignored.add(name);
      });
      expect(ignored, isEmpty, reason: '$className accepts but never reads: $ignored (read it, or mark it @Deprecated)');
    });
  }

  check('lib/mcp_client.dart', 'McpClientConfig');
  check('lib/mcp_client.dart', 'SseTransportConfig');
  check('lib/mcp_client.dart', 'StreamableHttpTransportConfig');
  check('lib/mcp_client.dart', 'StdioTransportConfig');
  check('lib/src/transport/streamable_http_transport.dart', 'StreamableHttpTransportConfig');
}
