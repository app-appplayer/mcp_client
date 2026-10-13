/// Elicitation values the client builds and reads (generated schema types):
/// every primitive schema kind's wire form, and `ElicitResult`.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('primitive schema kinds', () {
    test('string with every optional key', () {
      final json = StringSchema(
        title: 'Email',
        description: 'Work email',
        minLength: 3,
        maxLength: 64,
        format: StringSchemaFormat.email,
        defaultValue: 'a@b.c',
      ).toJson();
      expect(json, {
        'type': 'string',
        'title': 'Email',
        'description': 'Work email',
        'minLength': 3,
        'maxLength': 64,
        'format': 'email',
        'default': 'a@b.c',
      });
    });

    test('number and integer', () {
      expect(NumberSchema(type: NumberSchemaType.number, minimum: 0.5).toJson(),
          {'type': 'number', 'minimum': 0.5});
      expect(NumberSchema(type: NumberSchemaType.integer, maximum: 9, defaultValue: 3).toJson(),
          {'type': 'integer', 'maximum': 9, 'default': 3});
    });

    test('boolean with and without a default', () {
      expect(BooleanSchema().toJson(), {'type': 'boolean'});
      expect(BooleanSchema(defaultValue: false).toJson(), {'type': 'boolean', 'default': false});
    });

    test('a fragment the schema does not define is kept as unknown', () {
      final json = {'type': 'object', 'properties': <String, Object?>{}};
      final read = PrimitiveSchemaDefinition.fromJson(json);
      expect(read, isA<UnknownPrimitiveSchemaDefinition>());
      expect(read.toJson(), json);
    });
  });

  group('ElicitResult', () {
    test('accept carries content', () {
      expect(ElicitResult(action: ElicitResultAction.accept, content: {'name': 'x', 'n': 2, 'tags': ['a']}).toJson(),
          {'action': 'accept', 'content': {'name': 'x', 'n': 2, 'tags': ['a']}});
    });

    test('decline / cancel without content', () {
      expect(ElicitResult(action: ElicitResultAction.decline).toJson(), {'action': 'decline'});
      expect(ElicitResult(action: ElicitResultAction.cancel).toJson(), {'action': 'cancel'});
    });

    test('an unknown action is kept, not turned into cancel', () {
      final r = ElicitResult.fromJson({'action': 'defer'});
      expect(r.action.value, 'defer');
      expect(r.toJson(), {'action': 'defer'});
    });
  });
}
