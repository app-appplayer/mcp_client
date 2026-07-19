/// Typed model layer for `elicitation/create` (server → client) requests.
///
/// The wire protocol remains a raw JSON map — [Client.onElicitationRequest]
/// (the raw-map path) is unchanged and stays the source of truth on the
/// wire. This layer is an additive, lossless typed view over that map so
/// callers can inspect the requested schema without hand-parsing it.
///
/// Coverage (all spec 2025-11-25):
/// - [EnumSchema] with `enumNames` — titled and untitled enums.
/// - Single-select ([EnumElicitationField]) and multi-select
///   ([MultiSelectEnumElicitationField]) enums (SEP-1330).
/// - URL-mode elicitation (`mode: "url"`, SEP-1036) via
///   [ElicitationRequest.mode] / [ElicitationRequest.url].
/// - Default values on primitive fields (SEP-1034) via each field's
///   `defaultValue`.
library;

import 'package:meta/meta.dart';

/// Presentation mode of an elicitation request.
///
/// [form] (the pre-2025-11-25 behavior, and the default when the wire omits
/// `mode`) renders [ElicitationRequest.requestedSchema] as an input form.
/// [url] (SEP-1036, 2025-11-25) directs the client to open
/// [ElicitationRequest.url] so the user completes the flow out-of-band.
enum ElicitationMode { form, url }

/// The action a user took in response to an elicitation request.
enum ElicitationAction { accept, decline, cancel }

/// Typed view over an `elicitation/create` request's params.
@immutable
class ElicitationRequest {
  /// Human-readable prompt shown to the user.
  final String message;

  /// Presentation mode ([ElicitationMode.form] by default).
  final ElicitationMode mode;

  /// Destination URL for [ElicitationMode.url] requests (SEP-1036); null in
  /// form mode.
  final String? url;

  /// The raw requested schema (form mode). Preserved verbatim so nothing is
  /// lost even for shapes this layer does not specialize.
  final Map<String, dynamic>? requestedSchema;

  /// Typed parse of `requestedSchema.properties`, keyed by field name.
  final Map<String, ElicitationFieldSchema> fields;

  /// Names of required fields (`requestedSchema.required`).
  final List<String> requiredFields;

  /// The full raw params map, retained for lossless round-tripping.
  final Map<String, dynamic> raw;

  const ElicitationRequest({
    required this.message,
    required this.mode,
    this.url,
    this.requestedSchema,
    this.fields = const {},
    this.requiredFields = const [],
    required this.raw,
  });

  /// Whether this is a URL-mode request (SEP-1036).
  bool get isUrlMode => mode == ElicitationMode.url;

  factory ElicitationRequest.fromJson(Map<String, dynamic> params) {
    final modeStr = params['mode'] as String?;
    final mode =
        modeStr == 'url' ? ElicitationMode.url : ElicitationMode.form;

    final schema = params['requestedSchema'] != null
        ? Map<String, dynamic>.from(params['requestedSchema'] as Map)
        : null;

    final fields = <String, ElicitationFieldSchema>{};
    final props = schema?['properties'];
    if (props is Map) {
      props.forEach((key, value) {
        if (value is Map) {
          fields[key.toString()] = ElicitationFieldSchema.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      });
    }

    final requiredRaw = schema?['required'];
    final requiredFields = requiredRaw is List
        ? requiredRaw.map((e) => e.toString()).toList()
        : <String>[];

    return ElicitationRequest(
      message: params['message'] as String? ?? '',
      mode: mode,
      url: params['url'] as String?,
      requestedSchema: schema,
      fields: fields,
      requiredFields: requiredFields,
      raw: Map<String, dynamic>.from(params),
    );
  }

  /// Serialize back to the wire shape. Round-trips [raw] verbatim so any
  /// keys this layer does not model are preserved.
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(raw);
}

/// The enum descriptor shared by single- and multi-select elicitation
/// fields (spec 2025-11-25). [names] mirrors `enumNames` positionally: when
/// present the enum is *titled* (each value has a display label); when null
/// the enum is *untitled* (display the raw value).
@immutable
class EnumSchema {
  /// Allowed values (`enum`).
  final List<String> values;

  /// Display labels (`enumNames`), positionally aligned with [values]. Null
  /// for an untitled enum.
  final List<String>? names;

  const EnumSchema({required this.values, this.names});

  /// Whether this enum carries display labels.
  bool get isTitled => names != null;

  /// Display label for [value] — the aligned `enumNames` entry when titled,
  /// otherwise the raw value.
  String titleFor(String value) {
    final n = names;
    if (n == null) return value;
    final i = values.indexOf(value);
    return (i >= 0 && i < n.length) ? n[i] : value;
  }

  factory EnumSchema.fromJson(Map<String, dynamic> json) {
    final vals =
        (json['enum'] as List).map((e) => e.toString()).toList();
    final nm =
        (json['enumNames'] as List?)?.map((e) => e.toString()).toList();
    return EnumSchema(values: vals, names: nm);
  }

  Map<String, dynamic> toJson() => {
        'enum': values,
        if (names != null) 'enumNames': names,
      };
}

/// Base type for a single field inside an elicitation `requestedSchema`.
@immutable
sealed class ElicitationFieldSchema {
  /// Optional display title (`title`).
  final String? title;

  /// Optional description (`description`).
  final String? description;

  const ElicitationFieldSchema({this.title, this.description});

  Map<String, dynamic> toJson();

  /// Dispatch a raw JSON Schema fragment to the matching typed field.
  factory ElicitationFieldSchema.fromJson(Map<String, dynamic> json) {
    final type = json['type'];

    // Single-select enum: an `enum` present on a string (or untyped) schema.
    if (json['enum'] is List && (type == null || type == 'string')) {
      return EnumElicitationField.fromJson(json);
    }

    // Multi-select enum (SEP-1330): array whose items carry an `enum`.
    if (type == 'array') {
      final items = json['items'];
      if (items is Map && items['enum'] is List) {
        return MultiSelectEnumElicitationField.fromJson(json);
      }
      return GenericElicitationField.fromJson(json);
    }

    switch (type) {
      case 'string':
        return StringElicitationField.fromJson(json);
      case 'number':
      case 'integer':
        return NumberElicitationField.fromJson(json);
      case 'boolean':
        return BooleanElicitationField.fromJson(json);
      default:
        return GenericElicitationField.fromJson(json);
    }
  }
}

/// A free-text string field. Carries an optional [defaultValue] (SEP-1034).
@immutable
class StringElicitationField extends ElicitationFieldSchema {
  final String? defaultValue;
  final String? format;
  final int? minLength;
  final int? maxLength;

  const StringElicitationField({
    super.title,
    super.description,
    this.defaultValue,
    this.format,
    this.minLength,
    this.maxLength,
  });

  factory StringElicitationField.fromJson(Map<String, dynamic> json) {
    return StringElicitationField(
      title: json['title'] as String?,
      description: json['description'] as String?,
      defaultValue: json['default'] as String?,
      format: json['format'] as String?,
      minLength: (json['minLength'] as num?)?.toInt(),
      maxLength: (json['maxLength'] as num?)?.toInt(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'string',
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultValue != null) 'default': defaultValue,
        if (format != null) 'format': format,
        if (minLength != null) 'minLength': minLength,
        if (maxLength != null) 'maxLength': maxLength,
      };
}

/// A numeric field (`number` or `integer`). Carries an optional
/// [defaultValue] (SEP-1034).
@immutable
class NumberElicitationField extends ElicitationFieldSchema {
  /// Whether the JSON Schema type is `integer` (vs `number`).
  final bool integer;
  final num? defaultValue;
  final num? minimum;
  final num? maximum;

  const NumberElicitationField({
    super.title,
    super.description,
    this.integer = false,
    this.defaultValue,
    this.minimum,
    this.maximum,
  });

  factory NumberElicitationField.fromJson(Map<String, dynamic> json) {
    return NumberElicitationField(
      title: json['title'] as String?,
      description: json['description'] as String?,
      integer: json['type'] == 'integer',
      defaultValue: json['default'] as num?,
      minimum: json['minimum'] as num?,
      maximum: json['maximum'] as num?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': integer ? 'integer' : 'number',
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultValue != null) 'default': defaultValue,
        if (minimum != null) 'minimum': minimum,
        if (maximum != null) 'maximum': maximum,
      };
}

/// A boolean field. Carries an optional [defaultValue] (SEP-1034).
@immutable
class BooleanElicitationField extends ElicitationFieldSchema {
  final bool? defaultValue;

  const BooleanElicitationField({
    super.title,
    super.description,
    this.defaultValue,
  });

  factory BooleanElicitationField.fromJson(Map<String, dynamic> json) {
    return BooleanElicitationField(
      title: json['title'] as String?,
      description: json['description'] as String?,
      defaultValue: json['default'] as bool?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'boolean',
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultValue != null) 'default': defaultValue,
      };
}

/// A single-select enum field. Carries the [enumSchema] (values +
/// optional `enumNames`) and an optional [defaultValue] (SEP-1034).
@immutable
class EnumElicitationField extends ElicitationFieldSchema {
  final EnumSchema enumSchema;
  final String? defaultValue;

  const EnumElicitationField({
    super.title,
    super.description,
    required this.enumSchema,
    this.defaultValue,
  });

  factory EnumElicitationField.fromJson(Map<String, dynamic> json) {
    return EnumElicitationField(
      title: json['title'] as String?,
      description: json['description'] as String?,
      enumSchema: EnumSchema.fromJson(json),
      defaultValue: json['default'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'string',
        ...enumSchema.toJson(),
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultValue != null) 'default': defaultValue,
      };
}

/// A multi-select enum field (SEP-1330): a JSON Schema `array` whose
/// `items` are an enum. Carries the shared [enumSchema], an optional list
/// [defaultValue] (SEP-1034), and array constraints.
@immutable
class MultiSelectEnumElicitationField extends ElicitationFieldSchema {
  final EnumSchema enumSchema;
  final List<String>? defaultValue;
  final bool uniqueItems;
  final int? minItems;
  final int? maxItems;

  const MultiSelectEnumElicitationField({
    super.title,
    super.description,
    required this.enumSchema,
    this.defaultValue,
    this.uniqueItems = false,
    this.minItems,
    this.maxItems,
  });

  factory MultiSelectEnumElicitationField.fromJson(Map<String, dynamic> json) {
    final items = Map<String, dynamic>.from(json['items'] as Map);
    final def = (json['default'] as List?)
        ?.map((e) => e.toString())
        .toList();
    return MultiSelectEnumElicitationField(
      title: json['title'] as String?,
      description: json['description'] as String?,
      enumSchema: EnumSchema.fromJson(items),
      defaultValue: def,
      uniqueItems: json['uniqueItems'] as bool? ?? false,
      minItems: (json['minItems'] as num?)?.toInt(),
      maxItems: (json['maxItems'] as num?)?.toInt(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'array',
        'items': {
          'type': 'string',
          ...enumSchema.toJson(),
        },
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (uniqueItems) 'uniqueItems': true,
        if (minItems != null) 'minItems': minItems,
        if (maxItems != null) 'maxItems': maxItems,
        if (defaultValue != null) 'default': defaultValue,
      };
}

/// Fallback for a field shape this layer does not specialize. Preserves the
/// raw JSON Schema fragment so nothing is lost.
@immutable
class GenericElicitationField extends ElicitationFieldSchema {
  final Map<String, dynamic> raw;

  const GenericElicitationField({required this.raw})
      : super(title: null, description: null);

  factory GenericElicitationField.fromJson(Map<String, dynamic> json) {
    return GenericElicitationField(raw: Map<String, dynamic>.from(json));
  }

  @override
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(raw);
}

/// Typed response to an elicitation request. Serializes to the spec
/// `{ action, content? }` shape.
@immutable
class ElicitationResponse {
  final ElicitationAction action;

  /// Collected field values, present only for [ElicitationAction.accept].
  final Map<String, dynamic>? content;

  const ElicitationResponse({required this.action, this.content});

  /// Convenience constructor for an accepted response with [content].
  const ElicitationResponse.accept(this.content)
      : action = ElicitationAction.accept;

  /// Convenience constructor for a declined response.
  const ElicitationResponse.decline()
      : action = ElicitationAction.decline,
        content = null;

  /// Convenience constructor for a cancelled response.
  const ElicitationResponse.cancel()
      : action = ElicitationAction.cancel,
        content = null;

  Map<String, dynamic> toJson() => {
        'action': action.name,
        if (content != null) 'content': content,
      };

  factory ElicitationResponse.fromJson(Map<String, dynamic> json) {
    final actionStr = json['action'] as String?;
    final action = ElicitationAction.values.firstWhere(
      (a) => a.name == actionStr,
      orElse: () => ElicitationAction.cancel,
    );
    return ElicitationResponse(
      action: action,
      content: json['content'] != null
          ? Map<String, dynamic>.from(json['content'] as Map)
          : null,
    );
  }
}
