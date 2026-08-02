import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('timeHandler', () {
    test('date.today returns a MontyDate', () async {
      final handler = timeHandler();
      final result =
          (await handler('date.today', const [], null))! as MontyDate;

      expect(result.year, isA<int>());
      expect(result.month, isA<int>());
      expect(result.day, isA<int>());
    });

    test('datetime.now returns a MontyDateTime', () async {
      final handler = timeHandler();
      final result =
          (await handler('datetime.now', const [], null))! as MontyDateTime;

      expect(result.year, isA<int>());
      expect(result.month, isA<int>());
      expect(result.day, isA<int>());
      expect(result.hour, isA<int>());
      expect(result.minute, isA<int>());
      expect(result.second, isA<int>());
      expect(result.microsecond, isA<int>());
      expect(result.offsetSeconds, isA<int>());
      expect(result.timezoneName, isA<String>());
    });

    test('injected clock is used (frozen time)', () async {
      final frozen = DateTime(2026, 3, 15, 10, 30, 45, 123, 456);
      final handler = timeHandler(clock: () => frozen);

      final date = (await handler('date.today', const [], null))! as MontyDate;
      expect(date.year, 2026);
      expect(date.month, 3);
      expect(date.day, 15);

      final dt =
          (await handler('datetime.now', const [], null))! as MontyDateTime;
      expect(dt.year, 2026);
      expect(dt.hour, 10);
      expect(dt.minute, 30);
      expect(dt.second, 45);
    });

    test('unknown date/datetime operation throws', () {
      final handler = timeHandler();

      expect(
        () => handler('date.yesterday', const [], null),
        throwsUnsupportedError,
      );
      expect(
        () => handler('datetime.utcnow', const [], null),
        throwsUnsupportedError,
      );
    });

    test('default clock uses DateTime.now', () async {
      final handler = timeHandler();
      final before = DateTime.now();
      final result =
          (await handler('datetime.now', const [], null))! as MontyDateTime;
      final after = DateTime.now();

      expect(result.year, before.year);
      // Day should be within the range of the test run.
      expect(result.day, greaterThanOrEqualTo(before.day));
      expect(result.day, lessThanOrEqualTo(after.day));
    });

    test('timezone offset populated correctly', () async {
      final frozen = DateTime(2026, 6, 15, 12);
      final handler = timeHandler(clock: () => frozen);

      final result =
          (await handler('datetime.now', const [], null))! as MontyDateTime;
      expect(result.offsetSeconds, frozen.timeZoneOffset.inSeconds);
      expect(result.timezoneName, frozen.timeZoneName);
    });
  });
}
