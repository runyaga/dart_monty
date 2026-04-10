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

      test('coerces int for integer param', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(param.validate(42), 42);
      });

      test('coerces num to int for integer param', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(param.validate(3.7), 3);
      });

      test('coerces numeric string to int for integer param', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
        expect(param.validate('99'), 99);
      });

      test('throws FormatException for non-numeric string on integer', () {
        const param = HostParam(name: 'x', type: HostParamType.integer);
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

      test('coerces numeric string to num for number param', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
        expect(param.validate('2.5'), 2.5);
      });

      test('throws FormatException for non-numeric string on number', () {
        const param = HostParam(name: 'x', type: HostParamType.number);
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
