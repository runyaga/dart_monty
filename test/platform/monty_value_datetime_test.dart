import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // MontyDate
  // -------------------------------------------------------------------------
  group('MontyDate', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'date',
        'year': 2024,
        'month': 6,
        'day': 15,
      });
      expect(v, isA<MontyDate>());
      final date = v as MontyDate;
      expect(date.year, 2024);
      expect(date.month, 6);
      expect(date.day, 15);
    });

    test('toJson', () {
      const v = MontyDate(year: 2024, month: 6, day: 15);
      expect(v.toJson(), {
        '__type': 'date',
        'year': 2024,
        'month': 6,
        'day': 15,
      });
    });

    test('round-trip', () {
      const v = MontyDate(year: 2024, month: 6, day: 15);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyDate(year: 2024, month: 1, day: 1),
        equals(const MontyDate(year: 2024, month: 1, day: 1)),
      );
    });

    test('equality different', () {
      expect(
        const MontyDate(year: 2024, month: 1, day: 1),
        isNot(equals(const MontyDate(year: 2024, month: 1, day: 2))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyDate(year: 2024, month: 1, day: 1).hashCode,
        const MontyDate(year: 2024, month: 1, day: 1).hashCode,
      );
    });

    test('toString is non-empty', () {
      expect(
        const MontyDate(year: 2024, month: 1, day: 1).toString(),
        isNotEmpty,
      );
    });

    test('dartValue returns Map', () {
      const v = MontyDate(year: 2024, month: 1, day: 1);
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('boundary: year 1', () {
      const v = MontyDate(year: 1, month: 1, day: 1);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('boundary: year 9999', () {
      const v = MontyDate(year: 9999, month: 12, day: 31);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('boundary: leap day Feb 29', () {
      const v = MontyDate(year: 2024, month: 2, day: 29);
      expect(MontyValue.fromJson(v.toJson()), v);
    });
  });

  // -------------------------------------------------------------------------
  // MontyDateTime
  // -------------------------------------------------------------------------
  group('MontyDateTime', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'datetime',
        'year': 2024,
        'month': 6,
        'day': 15,
        'hour': 10,
        'minute': 30,
        'second': 45,
        'microsecond': 123456,
        'offset_seconds': 3600,
        'timezone_name': 'CET',
      });
      expect(v, isA<MontyDateTime>());
      final dt = v as MontyDateTime;
      expect(dt.year, 2024);
      expect(dt.hour, 10);
      expect(dt.microsecond, 123456);
      expect(dt.offsetSeconds, 3600);
      expect(dt.timezoneName, 'CET');
    });

    test('toJson', () {
      const v = MontyDateTime(
        year: 2024,
        month: 6,
        day: 15,
        hour: 10,
        minute: 30,
        second: 45,
      );
      final json = v.toJson();
      expect(json['__type'], 'datetime');
      expect(json['year'], 2024);
      expect(json['hour'], 10);
    });

    test('round-trip', () {
      const v = MontyDateTime(
        year: 2024,
        month: 6,
        day: 15,
        hour: 10,
        minute: 30,
        second: 45,
        microsecond: 100,
        offsetSeconds: -18000,
        timezoneName: 'EST',
      );
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      const a = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      const b = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      expect(a, equals(b));
    });

    test('equality different', () {
      const a = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      const b = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 1,
      );
      expect(a, isNot(equals(b)));
    });

    test('hashCode consistent', () {
      const a = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      const b = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      expect(a.hashCode, b.hashCode);
    });

    test('toString is non-empty', () {
      const v = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      expect(v.toString(), isNotEmpty);
    });

    test('dartValue returns Map', () {
      const v = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
      );
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('naive datetime (null offset)', () {
      final v = MontyValue.fromJson({
        '__type': 'datetime',
        'year': 2024,
        'month': 1,
        'day': 1,
        'hour': 12,
        'minute': 0,
        'second': 0,
      });
      final dt = v as MontyDateTime;
      expect(dt.offsetSeconds, isNull);
      expect(dt.timezoneName, isNull);
    });

    test('aware datetime UTC (offset=0)', () {
      const v = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
        offsetSeconds: 0,
        timezoneName: 'UTC',
      );
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('negative offset', () {
      const v = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
        offsetSeconds: -18000,
      );
      expect(MontyValue.fromJson(v.toJson()), v);
      expect(
        (MontyValue.fromJson(v.toJson()) as MontyDateTime).offsetSeconds,
        -18000,
      );
    });

    test('microseconds preserved', () {
      const v = MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
        microsecond: 999999,
      );
      final rt = MontyValue.fromJson(v.toJson()) as MontyDateTime;
      expect(rt.microsecond, 999999);
    });
  });

  // -------------------------------------------------------------------------
  // MontyTimeDelta
  // -------------------------------------------------------------------------
  group('MontyTimeDelta', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'timedelta',
        'days': 5,
        'seconds': 3600,
        'microseconds': 500,
      });
      expect(v, isA<MontyTimeDelta>());
      final td = v as MontyTimeDelta;
      expect(td.days, 5);
      expect(td.seconds, 3600);
      expect(td.microseconds, 500);
    });

    test('toJson', () {
      const v = MontyTimeDelta(days: 5, seconds: 3600);
      expect(v.toJson(), {
        '__type': 'timedelta',
        'days': 5,
        'seconds': 3600,
        'microseconds': 0,
      });
    });

    test('round-trip', () {
      const v = MontyTimeDelta(days: 5, seconds: 3600, microseconds: 500);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 0),
        equals(const MontyTimeDelta(days: 1, seconds: 0)),
      );
    });

    test('equality different', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 0),
        isNot(equals(const MontyTimeDelta(days: 2, seconds: 0))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyTimeDelta(days: 1, seconds: 0).hashCode,
        const MontyTimeDelta(days: 1, seconds: 0).hashCode,
      );
    });

    test('toString is non-empty', () {
      expect(const MontyTimeDelta(days: 0, seconds: 0).toString(), isNotEmpty);
    });

    test('dartValue returns Map', () {
      const v = MontyTimeDelta(days: 0, seconds: 0);
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('zero timedelta', () {
      const v = MontyTimeDelta(days: 0, seconds: 0);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('negative days', () {
      const v = MontyTimeDelta(days: -5, seconds: 100);
      expect(MontyValue.fromJson(v.toJson()), v);
      expect((MontyValue.fromJson(v.toJson()) as MontyTimeDelta).days, -5);
    });
  });

  // -------------------------------------------------------------------------
  // MontyTimeZone
  // -------------------------------------------------------------------------
  group('MontyTimeZone', () {
    test('fromJson', () {
      final v = MontyValue.fromJson({
        '__type': 'timezone',
        'offset_seconds': 3600,
        'name': 'CET',
      });
      expect(v, isA<MontyTimeZone>());
      final tz = v as MontyTimeZone;
      expect(tz.offsetSeconds, 3600);
      expect(tz.name, 'CET');
    });

    test('toJson', () {
      const v = MontyTimeZone(offsetSeconds: 3600, name: 'CET');
      expect(v.toJson(), {
        '__type': 'timezone',
        'offset_seconds': 3600,
        'name': 'CET',
      });
    });

    test('round-trip', () {
      const v = MontyTimeZone(offsetSeconds: 3600, name: 'CET');
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('equality same', () {
      expect(
        const MontyTimeZone(offsetSeconds: 0),
        equals(const MontyTimeZone(offsetSeconds: 0)),
      );
    });

    test('equality different', () {
      expect(
        const MontyTimeZone(offsetSeconds: 0),
        isNot(equals(const MontyTimeZone(offsetSeconds: 3600))),
      );
    });

    test('hashCode consistent', () {
      expect(
        const MontyTimeZone(offsetSeconds: 0).hashCode,
        const MontyTimeZone(offsetSeconds: 0).hashCode,
      );
    });

    test('toString is non-empty', () {
      expect(const MontyTimeZone(offsetSeconds: 0).toString(), isNotEmpty);
    });

    test('dartValue returns Map', () {
      const v = MontyTimeZone(offsetSeconds: 0);
      expect(v.dartValue, isA<Map<String, Object?>>());
    });

    test('UTC (offset 0, no name)', () {
      const v = MontyTimeZone(offsetSeconds: 0);
      expect(v.name, isNull);
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('named timezone', () {
      const v = MontyTimeZone(offsetSeconds: -18000, name: 'US/Eastern');
      expect(MontyValue.fromJson(v.toJson()), v);
    });
  });
}
