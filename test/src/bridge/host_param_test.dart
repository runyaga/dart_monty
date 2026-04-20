import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('HostParam', () {
    group('validate', () {
      test('returns value for valid string', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(param.validate('hello'), 'hello');
      });

      test('throws FormatException for wrong type on string', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(() => param.validate(123), throwsFormatException);
      });

      test('returns value for valid boolean', () {
        const param = HostParam(name: 'x', type: HostParamType.boolean);
        expect(param.validate(true), true);
      });

      test('throws FormatException for wrong type on boolean', () {
        const param = HostParam(name: 'x', type: HostParamType.boolean);
        expect(() => param.validate('true'), throwsFormatException);
      });

      test('accepts int for integer param', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(param.validate(42), 42);
      });

      test(
        'throws FormatException for float on integer param',
        () {
          // Floats are not losslessly coercible to int — reject always.
          const param = HostParam(name: 'x', type: HostParamType.integer);
          expect(() => param.validate(3.7), throwsFormatException);
          expect(() => param.validate(1.0), throwsFormatException);
        },
        // On JS/WASM, `1.0 is int` is true (unified num type), so this
        // coercion path is VM-only.
        testOn: 'vm',
      );

      test('throws FormatException for string on integer param', () {
        // Monty maps Python int → Dart int directly; a string means a
        // Python-side type error, not something dart_monty should paper over.
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(() => param.validate('99'), throwsFormatException);
        expect(() => param.validate('abc'), throwsFormatException);
      });

      test('throws FormatException for bool on integer', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(() => param.validate(true), throwsFormatException);
      });

      test('accepts num for number param', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(param.validate(3.14), 3.14);
        expect(param.validate(42), 42);
      });

      test('throws FormatException for string on number param', () {
        // Monty maps Python numeric types to Dart num directly; strings are
        // rejected, not coerced.
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(() => param.validate('2.5'), throwsFormatException);
        expect(() => param.validate('abc'), throwsFormatException);
      });

      test('throws FormatException for bool on number', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(() => param.validate(true), throwsFormatException);
      });

      test('accepts list for list param', () {
        const param = HostParam(name: 'x', type: HostParamType.list);
        expect(param.validate(<Object?>[1, 2, 3]), [1, 2, 3]);
      });

      test('throws FormatException for non-list on list param', () {
        const param = HostParam(name: 'x', type: HostParamType.list);
        expect(() => param.validate('not a list'), throwsFormatException);
      });

      test('accepts map for map param', () {
        const param = HostParam(name: 'x', type: HostParamType.map);
        final value = <String, Object?>{'a': 1};
        expect(param.validate(value), value);
      });

      test('throws FormatException for non-map on map param', () {
        const param = HostParam(name: 'x', type: HostParamType.map);
        expect(() => param.validate('not a map'), throwsFormatException);
      });

      test('passes through any value for any type', () {
        const param = HostParam(name: 'x', type: HostParamType.any);
        expect(param.validate('string'), 'string');
        expect(param.validate(42), 42);
        expect(param.validate(true), true);
      });
    });

    group('isRequired and defaultValue', () {
      test('throws FormatException when required param is null', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(() => param.validate(null), throwsFormatException);
      });

      test('returns defaultValue when optional param is null', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.integer,
          isRequired: false,
          defaultValue: 10,
        );
        expect(param.validate(null), 10);
      });

      test('returns null when optional param is null with no default', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.string,
          isRequired: false,
        );
        expect(param.validate(null), isNull);
      });

      test('validates provided value even when optional', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.integer,
          isRequired: false,
          defaultValue: 10,
        );
        expect(param.validate(5), 5);
      });
    });
  });

  group('renderAs / renderHintFrom', () {
    test('absent hint produces no render keys in JSON Schema', () {
      const param = HostParam(
        name: 'x',
        type: HostParamType.string,
        description: 'a string',
      );
      final schema = param.toJsonSchema();
      expect(schema.containsKey('x-render-as'), isFalse);
      expect(schema.containsKey('x-render-hint-from'), isFalse);
    });

    test('renderAs emits x-render-as with enum name', () {
      const param = HostParam(
        name: 'code',
        type: HostParamType.string,
        renderAs: ParamRenderHint.python,
      );
      expect(param.toJsonSchema()['x-render-as'], 'python');
    });

    test('renderHintFrom emits x-render-hint-from sibling name', () {
      const param = HostParam(
        name: 'script',
        type: HostParamType.string,
        renderHintFrom: 'language',
      );
      expect(param.toJsonSchema()['x-render-hint-from'], 'language');
    });

    test('render hint survives a jsonSchemaOverride', () {
      const param = HostParam(
        name: 'template',
        type: HostParamType.string,
        jsonSchemaOverride: {'type': 'string', 'minLength': 1},
        renderAs: ParamRenderHint.jinja,
      );
      final schema = param.toJsonSchema();
      expect(schema['type'], 'string');
      expect(schema['minLength'], 1);
      expect(schema['x-render-as'], 'jinja');
    });

    test('assert rejects both renderAs and renderHintFrom', () {
      expect(
        () => HostParam(
          name: 'x',
          type: HostParamType.string,
          renderAs: ParamRenderHint.python,
          renderHintFrom: 'language',
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('HostParamType', () {
    test('jsonSchemaType for each type', () {
      expect(HostParamType.string.jsonSchemaType, 'string');
      expect(HostParamType.integer.jsonSchemaType, 'integer');
      expect(HostParamType.number.jsonSchemaType, 'number');
      expect(HostParamType.boolean.jsonSchemaType, 'boolean');
      expect(HostParamType.list.jsonSchemaType, 'array');
      expect(HostParamType.map.jsonSchemaType, 'object');
      expect(HostParamType.any.jsonSchemaType, 'any');
    });

    test('all enum values are covered', () {
      expect(HostParamType.values, hasLength(7));
    });
  });
}
