// Extra coverage tests for MontyValue — exercises dartValue, toJson,
// and toString on every typed wrapper to boost line coverage.
import 'dart:convert';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  group('dartValue coverage', () {
    test('MontyBytes.dartValue returns List<int>', () {
      const v = MontyBytes([1, 2, 3]);
      expect(v.dartValue, [1, 2, 3]);
    });

    test('MontyTuple.dartValue returns List<Object?>', () {
      const v = MontyTuple([MontyInt(1), MontyString('a')]);
      expect(v.dartValue, [1, 'a']);
    });

    test('MontyDict.dartValue returns Map<String, Object?>', () {
      const v = MontyDict({'k': MontyInt(42)});
      expect(v.dartValue, {'k': 42});
    });

    test('MontySet.dartValue returns List<Object?>', () {
      const v = MontySet([MontyInt(1)]);
      expect(v.dartValue, [1]);
    });

    test('MontyFrozenSet.dartValue returns List<Object?>', () {
      const v = MontyFrozenSet([MontyInt(2)]);
      expect(v.dartValue, [2]);
    });

    test('MontyList.dartValue returns List<Object?>', () {
      const v = MontyList([MontyBool(true), MontyNull()]);
      expect(v.dartValue, [true, null]);
    });

    test('MontyDate.dartValue returns DateTime', () {
      const v = MontyDate(year: 2026, month: 4, day: 10);
      final dv = v.dartValue;
      expect(dv, isA<DateTime>());
      expect(dv.year, 2026);
      expect(dv.month, 4);
      expect(dv.day, 10);
    });

    test('MontyDateTime.dartValue returns DateTime', () {
      const v = MontyDateTime(
        year: 2026,
        month: 4,
        day: 10,
        hour: 12,
        minute: 0,
        second: 0,
      );
      final dv = v.dartValue;
      expect(dv, isA<DateTime>());
      expect(dv.year, 2026);
      expect(dv.hour, 12);
    });

    test('MontyTimeDelta.dartValue returns Duration', () {
      const v = MontyTimeDelta(days: 1, seconds: 0);
      final dv = v.dartValue;
      expect(dv, isA<Duration>());
      expect(dv.inDays, 1);
    });

    test('MontyTimeZone.dartValue returns map', () {
      const v = MontyTimeZone(offsetSeconds: 0);
      final dv = v.dartValue;
      expect(dv['__type'], 'timezone');
    });

    test('MontyPath.dartValue returns string', () {
      const v = MontyPath('/tmp');
      expect(v.dartValue, '/tmp');
    });

    test('MontyNamedTuple.dartValue returns map', () {
      const v = MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      );
      final dv = v.dartValue;
      expect(dv['__type'], 'namedtuple');
    });

    test('MontyDataclass.dartValue returns map', () {
      const v = MontyDataclass(
        name: 'C',
        typeId: 1,
        fieldNames: ['a'],
        attrs: {'a': MontyInt(1)},
      );
      final dv = v.dartValue;
      expect(dv['__type'], 'dataclass');
    });
  });

  group('toJson round-trip via json.encode', () {
    test('all typed wrappers survive json encode/decode', () {
      final values = <MontyValue>[
        const MontyNull(),
        const MontyBool(true),
        const MontyInt(42),
        const MontyFloat(3.14),
        const MontyString('hello'),
        const MontyBytes([0, 255]),
        const MontyList([MontyInt(1)]),
        const MontyTuple([MontyString('a')]),
        const MontyDict({'k': MontyInt(1)}),
        const MontySet([MontyInt(1)]),
        const MontyFrozenSet([MontyInt(2)]),
        const MontyDate(year: 2026, month: 1, day: 1),
        const MontyDateTime(
          year: 2026,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
        ),
        const MontyTimeDelta(days: 0, seconds: 0),
        const MontyTimeZone(offsetSeconds: 0),
        const MontyPath('/x'),
        const MontyNamedTuple(typeName: 'T', fieldNames: [], values: []),
        const MontyDataclass(name: 'D', typeId: 0, fieldNames: [], attrs: {}),
      ];

      for (final v in values) {
        final jsonStr = json.encode(v.toJson());
        final decoded = json.decode(jsonStr);
        final back = MontyValue.fromJson(decoded);
        expect(
          back.runtimeType,
          v.runtimeType,
          reason: '${v.runtimeType} should round-trip through JSON',
        );
      }
    });
  });

  group('toString coverage', () {
    test('all types have non-empty toString', () {
      final values = <MontyValue>[
        const MontyNull(),
        const MontyBool(false),
        const MontyInt(0),
        const MontyFloat(0),
        const MontyString(''),
        const MontyBytes([]),
        const MontyList([]),
        const MontyTuple([]),
        const MontyDict({}),
        const MontySet([]),
        const MontyFrozenSet([]),
        const MontyDate(year: 1, month: 1, day: 1),
        const MontyDateTime(
          year: 1,
          month: 1,
          day: 1,
          hour: 0,
          minute: 0,
          second: 0,
        ),
        const MontyTimeDelta(days: 0, seconds: 0),
        const MontyTimeZone(offsetSeconds: 0),
        const MontyPath(''),
        const MontyNamedTuple(typeName: '', fieldNames: [], values: []),
        const MontyDataclass(name: '', typeId: 0, fieldNames: [], attrs: {}),
      ];

      for (final v in values) {
        expect(v.toString(), isNotEmpty, reason: '${v.runtimeType}.toString()');
      }
    });
  });
}
