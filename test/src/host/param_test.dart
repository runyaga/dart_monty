// Explicit float spelling documents numeric kind and signed zero.
// ignore_for_file: prefer_int_literals
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('HostParam', () {
    group('validate', () {
      test('returns value for valid string', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(param.validate(const MontyString('hello')).dartValue, 'hello');
      });

      test('throws FormatException for wrong type on string', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(
          () => param.validate(const MontyInt(123)),
          throwsFormatException,
        );
      });

      test('returns value for valid boolean', () {
        const param = HostParam(name: 'x', type: HostParamType.boolean);
        expect(param.validate(const MontyBool(true)).dartValue, true);
      });

      test('throws FormatException for wrong type on boolean', () {
        const param = HostParam(name: 'x', type: HostParamType.boolean);
        expect(
          () => param.validate(const MontyString('true')),
          throwsFormatException,
        );
      });

      test('accepts int for integer param', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(param.validate(const MontyInt(42)).dartValue, 42);
      });

      test(
        'throws FormatException for float on integer param',
        () {
          // Floats are not losslessly coercible to int — reject always.
          const param = HostParam(name: 'x', type: HostParamType.integer);
          expect(
            () => param.validate(const MontyFloat(3.7)),
            throwsFormatException,
          );
          expect(
            () => param.validate(const MontyFloat(1.0)),
            throwsFormatException,
          );
        },
      );

      test('throws FormatException for string on integer param', () {
        // Monty maps Python int → Dart int directly; a string means a
        // Python-side type error, not something dart_monty should paper over.
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(
          () => param.validate(const MontyString('99')),
          throwsFormatException,
        );
        expect(
          () => param.validate(const MontyString('abc')),
          throwsFormatException,
        );
      });

      test('throws FormatException for bool on integer', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(
          () => param.validate(const MontyBool(true)),
          throwsFormatException,
        );
      });

      test('accepts num for number param', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(param.validate(const MontyFloat(3.14)).dartValue, 3.14);
        expect(param.validate(const MontyInt(42)).dartValue, 42);
      });

      test('throws FormatException for string on number param', () {
        // Monty maps Python numeric types to Dart num directly; strings are
        // rejected, not coerced.
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(
          () => param.validate(const MontyString('2.5')),
          throwsFormatException,
        );
        expect(
          () => param.validate(const MontyString('abc')),
          throwsFormatException,
        );
      });

      test('throws FormatException for bool on number', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(
          () => param.validate(const MontyBool(true)),
          throwsFormatException,
        );
      });

      test('accepts list for list param', () {
        const param = HostParam(name: 'x', type: HostParamType.list);
        expect(
          param.validate(MontyValue.fromDart(<Object?>[1, 2, 3])).dartValue,
          [1, 2, 3],
        );
      });

      test('throws FormatException for non-list on list param', () {
        const param = HostParam(name: 'x', type: HostParamType.list);
        expect(
          () => param.validate(const MontyString('not a list')),
          throwsFormatException,
        );
      });

      test('accepts map for map param', () {
        const param = HostParam(name: 'x', type: HostParamType.map);
        final value = <String, Object?>{'a': 1};
        expect(param.validate(MontyValue.fromDart(value)).dartValue, value);
      });

      test('throws FormatException for non-map on map param', () {
        const param = HostParam(name: 'x', type: HostParamType.map);
        expect(
          () => param.validate(const MontyString('not a map')),
          throwsFormatException,
        );
      });

      test('accepts a dynamically-keyed map whose keys are all strings', () {
        // The shape a Python dict actually arrives in since dart_monty_core
        // merged MontyPairsDict into MontyDict: `dartValue` lowers it as
        // Map<Object?, Object?>, which is NOT a Map<String, Object?> even when
        // every key is a String. Rejecting it broke every map-typed host
        // parameter -- el_emit among them -- at the boundary rather than in
        // the sandbox.
        const param = HostParam(name: 'x', type: HostParamType.map);
        final wire = <Object?, Object?>{'type': 'counter', 'value': 0};

        final out = param.validate(MontyValue.fromDart(wire)).dartValue;

        expect(out, isA<Map<Object?, Object?>>());
        expect(out, {'type': 'counter', 'value': 0});
      });

      test('preserves non-string dict keys', () {
        const param = HostParam(name: 'x', type: HostParamType.map);
        const value = MontyDict([(MontyInt(2), MontyString('two'))]);
        expect(param.validate(value), same(value));
      });

      test('an empty dynamically-keyed map is accepted, not rejected', () {
        const param = HostParam(name: 'x', type: HostParamType.map);

        expect(
          param.validate(MontyValue.fromDart(<Object?, Object?>{})).dartValue,
          isEmpty,
        );
      });

      test('passes through any value for any type', () {
        const param = HostParam(name: 'x', type: HostParamType.any);
        expect(param.validate(const MontyString('string')).dartValue, 'string');
        expect(param.validate(const MontyInt(42)).dartValue, 42);
        expect(param.validate(const MontyBool(true)).dartValue, true);
      });
    });

    group('isRequired and defaultValue', () {
      test('throws FormatException when required param is null', () {
        const param = HostParam(name: 'x', type: HostParamType.string);
        expect(() => param.validate(const MontyNone()), throwsFormatException);
      });

      test('returns defaultValue when optional param is omitted', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.integer,
          isRequired: false,
          defaultValue: MontyInt(10),
        );
        expect(param.validate(null, isPresent: false).dartValue, 10);
      });

      test('returns null when optional param is null with no default', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.string,
          isRequired: false,
        );
        expect(param.validate(const MontyNone()).dartValue, isNull);
      });

      test('validates provided value even when optional', () {
        const param = HostParam(
          name: 'x',
          type: HostParamType.integer,
          isRequired: false,
          defaultValue: MontyInt(10),
        );
        expect(param.validate(const MontyInt(5)).dartValue, 5);
      });
    });
  });

  group('HostParam.validate and the explicit-null sentinel', () {
    // Presence and Python None are independent: an explicit None reaches
    // an any-typed handler, while a missing required argument is rejected.
    test('required any-typed param accepts an explicitly supplied null', () {
      const param = HostParam(name: 'message', type: HostParamType.any);
      expect(param.validate(const MontyNone()).dartValue, isNull);
    });

    test('required any-typed param still rejects being omitted', () {
      const param = HostParam(name: 'message', type: HostParamType.any);
      expect(
        () => param.validate(null, isPresent: false),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('is missing'),
          ),
        ),
      );
    });

    test('required typed param still rejects a null value', () {
      // null is not a String, however it arrived.
      const param = HostParam(name: 'name', type: HostParamType.string);
      expect(
        () => param.validate(const MontyNone()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('is null'),
          ),
        ),
      );
      expect(
        () => param.validate(null, isPresent: false),
        throwsFormatException,
      );
    });

    test('optional param selects default only on omission', () {
      const param = HostParam(
        name: 'count',
        type: HostParamType.integer,
        isRequired: false,
        defaultValue: MontyInt(7),
      );
      expect(param.validate(const MontyNone()).dartValue, isNull);
      expect(param.validate(null, isPresent: false).dartValue, 7);
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

  group('jsonSchemaOverride', () {
    const override = {
      'type': 'string',
      'enum': ['a', 'b'],
    };
    const param = HostParam(
      name: 'mode',
      type: HostParamType.integer,
      jsonSchemaOverride: override,
    );

    test('toJsonSchema returns a copy of it', () {
      final schema = param.toJsonSchema()..['type'] = 'changed';

      expect(schema, isNot(same(override)));
      expect(param.toJsonSchema(), override);
    });

    test('validation still uses type', () {
      expect(param.validate(const MontyInt(3)).dartValue, 3);
      expect(
        () => param.validate(const MontyString('a')),
        throwsFormatException,
      );
    });
  });

  test('missing and None name the parameter', () {
    const param = HostParam(name: 'x', type: HostParamType.string);

    expect(
      () => param.validate(null, isPresent: false),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Required parameter "x" is missing',
        ),
      ),
    );
    expect(
      () => param.validate(const MontyNone()),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Required parameter "x" is null',
        ),
      ),
    );
  });
}
