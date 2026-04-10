import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // MontyNull
  // -------------------------------------------------------------------------
  group('MontyNull', () {
    test('fromJson with null', () {
      expect(MontyValue.fromJson(null), isA<MontyNull>());
    });

    test('toJson returns null', () {
      expect(const MontyNull().toJson(), isNull);
    });

    test('round-trip', () {
      const v = MontyNull();
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality', () {
      expect(const MontyNull(), equals(const MontyNull()));
    });

    test('hashCode consistent with ==', () {
      expect(const MontyNull().hashCode, const MontyNull().hashCode);
    });

    test('toString is non-empty', () {
      expect(const MontyNull().toString(), isNotEmpty);
    });

    test('dartValue returns null', () {
      expect(const MontyNull().dartValue, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // MontyBool
  // -------------------------------------------------------------------------
  group('MontyBool', () {
    test('fromJson with true', () {
      final v = MontyValue.fromJson(true);
      expect(v, isA<MontyBool>());
      expect((v as MontyBool).value, isTrue);
    });

    test('fromJson with false', () {
      final v = MontyValue.fromJson(false);
      expect((v as MontyBool).value, isFalse);
    });

    test('toJson', () {
      expect(const MontyBool(true).toJson(), true);
      expect(const MontyBool(false).toJson(), false);
    });

    test('round-trip', () {
      const v = MontyBool(true);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same values', () {
      expect(const MontyBool(true), equals(const MontyBool(true)));
    });

    test('equality different values', () {
      expect(const MontyBool(true), isNot(equals(const MontyBool(false))));
    });

    test('hashCode consistent with ==', () {
      expect(const MontyBool(true).hashCode, const MontyBool(true).hashCode);
    });

    test('toString is non-empty', () {
      expect(const MontyBool(true).toString(), isNotEmpty);
    });

    test('dartValue returns bool', () {
      expect(const MontyBool(true).dartValue, isA<bool>());
      expect(const MontyBool(true).dartValue, true);
    });
  });

  // -------------------------------------------------------------------------
  // MontyInt
  // -------------------------------------------------------------------------
  group('MontyInt', () {
    test('fromJson with int', () {
      final v = MontyValue.fromJson(42);
      expect(v, isA<MontyInt>());
      expect((v as MontyInt).value, 42);
    });

    test('toJson', () {
      expect(const MontyInt(42).toJson(), 42);
    });

    test('round-trip', () {
      const v = MontyInt(42);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(const MontyInt(7), equals(const MontyInt(7)));
    });

    test('equality different', () {
      expect(const MontyInt(7), isNot(equals(const MontyInt(8))));
    });

    test('hashCode consistent', () {
      expect(const MontyInt(7).hashCode, const MontyInt(7).hashCode);
    });

    test('toString is non-empty', () {
      expect(const MontyInt(7).toString(), isNotEmpty);
    });

    test('dartValue returns int', () {
      expect(const MontyInt(42).dartValue, isA<int>());
      expect(const MontyInt(42).dartValue, 42);
    });

    test('negative int', () {
      final v = MontyValue.fromJson(-100);
      expect(v, isA<MontyInt>());
      expect((v as MontyInt).value, -100);
    });

    test('zero', () {
      final v = MontyValue.fromJson(0);
      expect(v, isA<MontyInt>());
      expect((v as MontyInt).value, 0);
    });
  });

  // -------------------------------------------------------------------------
  // MontyFloat
  // -------------------------------------------------------------------------
  group('MontyFloat', () {
    test('fromJson with double', () {
      final v = MontyValue.fromJson(3.14);
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value, 3.14);
    });

    test('toJson', () {
      expect(const MontyFloat(3.14).toJson(), 3.14);
    });

    test('round-trip', () {
      const v = MontyFloat(3.14);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(const MontyFloat(1.5), equals(const MontyFloat(1.5)));
    });

    test('equality different', () {
      expect(const MontyFloat(1.5), isNot(equals(const MontyFloat(2.5))));
    });

    test('hashCode consistent', () {
      expect(const MontyFloat(1.5).hashCode, const MontyFloat(1.5).hashCode);
    });

    test('toString is non-empty', () {
      expect(const MontyFloat(1.5).toString(), isNotEmpty);
    });

    test('dartValue returns double', () {
      expect(const MontyFloat(3.14).dartValue, isA<double>());
    });

    // Special float values
    test('NaN serialization', () {
      const v = MontyFloat(double.nan);
      expect(v.toJson(), 'NaN');
    });

    test('NaN deserialization', () {
      final v = MontyValue.fromJson('NaN');
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value.isNaN, isTrue);
    });

    test('NaN round-trip', () {
      const v = MontyFloat(double.nan);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('NaN == NaN is true', () {
      expect(const MontyFloat(double.nan), equals(const MontyFloat(double.nan)));
    });

    test('NaN hashCode is consistent', () {
      expect(
        const MontyFloat(double.nan).hashCode,
        const MontyFloat(double.nan).hashCode,
      );
    });

    test('Infinity serialization', () {
      const v = MontyFloat(double.infinity);
      expect(v.toJson(), 'Infinity');
    });

    test('Infinity deserialization', () {
      final v = MontyValue.fromJson('Infinity');
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value, double.infinity);
    });

    test('Infinity round-trip', () {
      const v = MontyFloat(double.infinity);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('-Infinity serialization', () {
      const v = MontyFloat(double.negativeInfinity);
      expect(v.toJson(), '-Infinity');
    });

    test('-Infinity deserialization', () {
      final v = MontyValue.fromJson('-Infinity');
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value, double.negativeInfinity);
    });

    test('-Infinity round-trip', () {
      const v = MontyFloat(double.negativeInfinity);
      expect(MontyValue.fromJson(v.toJson()), v);
    });
  });

  // -------------------------------------------------------------------------
  // MontyInt vs MontyFloat disambiguation
  // -------------------------------------------------------------------------
  group('MontyInt vs MontyFloat', () {
    test('fromJson(42) produces MontyInt', () {
      expect(MontyValue.fromJson(42), isA<MontyInt>());
    });

    test('fromJson(42.0) produces MontyFloat', () {
      expect(MontyValue.fromJson(42.0), isA<MontyFloat>());
    });
  });

  // -------------------------------------------------------------------------
  // MontyString
  // -------------------------------------------------------------------------
  group('MontyString', () {
    test('fromJson with string', () {
      final v = MontyValue.fromJson('hello');
      expect(v, isA<MontyString>());
      expect((v as MontyString).value, 'hello');
    });

    test('toJson', () {
      expect(const MontyString('hello').toJson(), 'hello');
    });

    test('round-trip', () {
      const v = MontyString('hello');
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(const MontyString('a'), equals(const MontyString('a')));
    });

    test('equality different', () {
      expect(const MontyString('a'), isNot(equals(const MontyString('b'))));
    });

    test('hashCode consistent', () {
      expect(
        const MontyString('a').hashCode,
        const MontyString('a').hashCode,
      );
    });

    test('toString is non-empty', () {
      expect(const MontyString('hello').toString(), isNotEmpty);
    });

    test('dartValue returns String', () {
      expect(const MontyString('hello').dartValue, isA<String>());
      expect(const MontyString('hello').dartValue, 'hello');
    });

    test('empty string', () {
      final v = MontyValue.fromJson('');
      expect(v, isA<MontyString>());
      expect((v as MontyString).value, '');
    });
  });
}
