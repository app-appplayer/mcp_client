import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// Round-trip coverage for the typed elicitation field serializers and the
/// [ElicitationResponse] type (A4/A5, SEP-1330/1034/1036). The pre-existing
/// A4 test parses field shapes but does not exercise every field's `toJson`
/// nor the response envelope; these serializers are pure logic and must be
/// covered to the 100% pure-logic bar.
void main() {
  group('Typed elicitation field toJson round-trips', () {
    test('StringElicitationField emits every optional key', () {
      const field = StringElicitationField(
        title: 'Name',
        description: 'Your name',
        defaultValue: 'anon',
        format: 'email',
        minLength: 2,
        maxLength: 40,
      );
      final json = field.toJson();
      expect(json, equals({
        'type': 'string',
        'title': 'Name',
        'description': 'Your name',
        'default': 'anon',
        'format': 'email',
        'minLength': 2,
        'maxLength': 40,
      }));
      // fromJson(toJson) is stable.
      final rt = ElicitationFieldSchema.fromJson(json) as StringElicitationField;
      expect(rt.toJson(), equals(json));
    });

    test('StringElicitationField omits absent optionals', () {
      const field = StringElicitationField();
      expect(field.toJson(), equals({'type': 'string'}));
    });

    test('NumberElicitationField number vs integer variants', () {
      const number = NumberElicitationField(
        title: 'Amount',
        defaultValue: 1.5,
        minimum: 0,
        maximum: 10,
      );
      expect(number.toJson(), equals({
        'type': 'number',
        'title': 'Amount',
        'default': 1.5,
        'minimum': 0,
        'maximum': 10,
      }));

      const integer = NumberElicitationField(integer: true, defaultValue: 3);
      expect(integer.toJson(), equals({'type': 'integer', 'default': 3}));

      final rt = ElicitationFieldSchema.fromJson(integer.toJson())
          as NumberElicitationField;
      expect(rt.integer, isTrue);
      expect(rt.toJson(), equals(integer.toJson()));
    });

    test('BooleanElicitationField with and without a default', () {
      const withDefault =
          BooleanElicitationField(description: 'agree', defaultValue: true);
      expect(withDefault.toJson(), equals({
        'type': 'boolean',
        'description': 'agree',
        'default': true,
      }));
      const bare = BooleanElicitationField();
      expect(bare.toJson(), equals({'type': 'boolean'}));
    });

    test('GenericElicitationField preserves an unspecialized fragment', () {
      final raw = {'type': 'string', 'pattern': r'^\d+$', 'x-vendor': 42};
      final field = GenericElicitationField.fromJson(raw);
      expect(field.raw, equals(raw));
      expect(field.toJson(), equals(raw));
      // The dispatcher falls back to Generic for shapes it does not model
      // (no `enum`, non-primitive type).
      final dispatched = ElicitationFieldSchema.fromJson(
          {'type': 'object', 'properties': <String, dynamic>{}});
      expect(dispatched, isA<GenericElicitationField>());
      // An `array` whose items carry no `enum` is not a multi-select; it
      // falls back to Generic rather than MultiSelectEnum.
      final plainArray = ElicitationFieldSchema.fromJson(
          {'type': 'array', 'items': {'type': 'string'}});
      expect(plainArray, isA<GenericElicitationField>());
    });
  });

  group('ElicitationResponse', () {
    test('accept carries content', () {
      final r = ElicitationResponse.accept({'name': 'ada'});
      expect(r.action, ElicitationAction.accept);
      expect(r.toJson(), equals({
        'action': 'accept',
        'content': {'name': 'ada'},
      }));
    });

    test('decline / cancel omit content', () {
      expect(const ElicitationResponse.decline().toJson(),
          equals({'action': 'decline'}));
      expect(const ElicitationResponse.cancel().toJson(),
          equals({'action': 'cancel'}));
    });

    test('fromJson round-trips accept with content', () {
      final parsed = ElicitationResponse.fromJson({
        'action': 'accept',
        'content': {'q': 1},
      });
      expect(parsed.action, ElicitationAction.accept);
      expect(parsed.content, equals({'q': 1}));
      expect(parsed.toJson(),
          equals({'action': 'accept', 'content': {'q': 1}}));
    });

    test('fromJson defaults an unknown/absent action to cancel', () {
      expect(ElicitationResponse.fromJson({'action': 'bogus'}).action,
          ElicitationAction.cancel);
      expect(ElicitationResponse.fromJson(<String, dynamic>{}).action,
          ElicitationAction.cancel);
    });
  });
}
