import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // Dispatch and fallback
  // -------------------------------------------------------------------------
  group('dispatch and fallback', () {
    test('unknown __type falls to MontyDict', () {
      final v = MontyValue.fromJson({
        '__type': 'unknown_custom_type',
        'data': 123,
      });
      expect(v, isA<MontyDict>());
      final dict = v as MontyDict;
      expect(dict.entries['__type'], isA<MontyString>());
      expect(
        (dict.entries['__type']! as MontyString).value,
        'unknown_custom_type',
      );
    });

    test('fromJson with non-JSON input falls to MontyString', () {
      // Objects that are not null/bool/int/double/String/List/Map
      // fall through to MontyString(json.toString())
      final v = MontyValue.fromJson(Object());
      expect(v, isA<MontyString>());
      expect((v as MontyString).value, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Recursive nesting
  // -------------------------------------------------------------------------
  group('recursive nesting', () {
    test('list containing tuple containing date', () {
      const date = MontyDate(year: 2024, month: 6, day: 15);
      const tuple = MontyTuple([date, MontyString('label')]);
      const list = MontyList([tuple, MontyInt(42)]);

      final json = list.toJson();
      final rt = MontyValue.fromJson(json);

      expect(rt, isA<MontyList>());
      final rtList = rt as MontyList;
      expect(rtList.items[0], isA<MontyTuple>());
      final rtTuple = rtList.items[0] as MontyTuple;
      expect(rtTuple.items[0], isA<MontyDate>());
      expect(rtTuple.items[0], date);
      expect(rtList.items[1], const MontyInt(42));
    });

    test('dict containing list containing set', () {
      const set = MontySet([MontyInt(1), MontyInt(2)]);
      const list = MontyList([set, MontyBool(true)]);
      const dict = MontyDict({'data': list});

      final rt = MontyValue.fromJson(dict.toJson()) as MontyDict;
      final rtList = rt.entries['data']! as MontyList;
      expect(rtList.items[0], isA<MontySet>());
    });
  });
}
