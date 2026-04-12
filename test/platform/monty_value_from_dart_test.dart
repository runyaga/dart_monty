import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  group('MontyValue.fromDart', () {
    test('null produces MontyNull', () {
      final v = MontyValue.fromDart(null);
      expect(v, isA<MontyNull>());
    });

    test('bool produces MontyBool', () {
      final v = MontyValue.fromDart(true);
      expect(v, isA<MontyBool>());
      expect((v as MontyBool).value, isTrue);
    });

    test('false produces MontyBool(false)', () {
      final v = MontyValue.fromDart(false);
      expect((v as MontyBool).value, isFalse);
    });

    test('int produces MontyInt', () {
      final v = MontyValue.fromDart(42);
      expect(v, isA<MontyInt>());
      expect((v as MontyInt).value, 42);
    });

    test('double produces MontyFloat', () {
      final v = MontyValue.fromDart(3.14);
      expect(v, isA<MontyFloat>());
      expect((v as MontyFloat).value, 3.14);
    });

    test('String produces MontyString', () {
      final v = MontyValue.fromDart('hello');
      expect(v, isA<MontyString>());
      expect((v as MontyString).value, 'hello');
    });

    test('DateTime produces MontyDateTime in UTC', () {
      final dt = DateTime(2026, 4, 10, 15, 30, 45);
      final v = MontyValue.fromDart(dt);
      expect(v, isA<MontyDateTime>());
      final mdv = v as MontyDateTime;
      final utc = dt.toUtc();
      expect(mdv.year, utc.year);
      expect(mdv.month, utc.month);
      expect(mdv.day, utc.day);
      expect(mdv.hour, utc.hour);
      expect(mdv.minute, utc.minute);
      expect(mdv.second, utc.second);
      expect(mdv.microsecond, utc.microsecond);
    });

    test('List produces MontyList with recursive conversion', () {
      final v = MontyValue.fromDart([1, 2, 3]);
      expect(v, isA<MontyList>());
      final list = v as MontyList;
      expect(list.items, [
        const MontyInt(1),
        const MontyInt(2),
        const MontyInt(3),
      ]);
    });

    test('List with mixed types', () {
      final v = MontyValue.fromDart([1, 'two', true, null]);
      expect(v, isA<MontyList>());
      final list = v as MontyList;
      expect(list.items, [
        const MontyInt(1),
        const MontyString('two'),
        const MontyBool(true),
        const MontyNull(),
      ]);
    });

    test('Map produces MontyDict with recursive conversion', () {
      final v = MontyValue.fromDart({'a': 1, 'b': 'two'});
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(dict.entries['a'], const MontyInt(1));
      expect(dict.entries['b'], const MontyString('two'));
    });

    test('Map with non-string keys coerces to String', () {
      final v = MontyValue.fromDart({1: 'one', 2: 'two'});
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(dict.entries['1'], const MontyString('one'));
      expect(dict.entries['2'], const MontyString('two'));
    });

    test('MontyValue passthrough (MontyInt)', () {
      const original = MontyInt(5);
      final v = MontyValue.fromDart(original);
      expect(identical(v, original), isTrue);
    });

    test('MontyValue passthrough (MontyString)', () {
      const original = MontyString('pass');
      final v = MontyValue.fromDart(original);
      expect(identical(v, original), isTrue);
    });

    test('MontyValue passthrough (MontyNull)', () {
      const original = MontyNull();
      final v = MontyValue.fromDart(original);
      expect(identical(v, original), isTrue);
    });

    test('unsupported type throws ArgumentError', () {
      expect(
        () => MontyValue.fromDart(Uri.parse('https://example.com')),
        throwsArgumentError,
      );
    });

    test('nested List of Maps', () {
      final v = MontyValue.fromDart([
        {'x': 1},
        {'y': 2},
      ]);
      expect(v, isA<MontyList>());
      final list = v as MontyList;
      expect(list.items[0], isA<MontyDict>());
      expect(list.items[1], isA<MontyDict>());
    });
  });

  group('MontyValue._parseMap edge cases', () {
    test('map without __type produces MontyDict', () {
      final v = MontyValue.fromJson({'foo': 1, 'bar': 'baz'});
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(dict.entries['foo'], const MontyInt(1));
      expect(dict.entries['bar'], const MontyString('baz'));
    });

    test('unknown __type falls back to MontyDict', () {
      final v = MontyValue.fromJson({
        '__type': 'completely_unknown_type',
        'data': 42,
      });
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(
        (dict.entries['__type']! as MontyString).value,
        'completely_unknown_type',
      );
      expect(dict.entries['data'], const MontyInt(42));
    });
  });

  group('MontyValue.fromJson special float strings', () {
    test('other strings are MontyString', () {
      final v = MontyValue.fromJson('not_infinity');
      expect(v, isA<MontyString>());
      expect((v as MontyString).value, 'not_infinity');
    });
  });
}
