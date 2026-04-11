import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall fakeOsCall(String op) => MontyOsCall(
    operationName: op,
    arguments: const [],
  );

  group('TimeOsCallHandler', () {
    test('date.today returns date map with __type', () async {
      final handler = TimeOsCallHandler();
      final result =
          (await handler.handle(fakeOsCall('date.today')))!
              as Map<String, Object?>;

      expect(result['__type'], 'date');
      expect(result['year'], isA<int>());
      expect(result['month'], isA<int>());
      expect(result['day'], isA<int>());
      expect(result.containsKey('hour'), isFalse);
    });

    test('datetime.now returns datetime map with __type', () async {
      final handler = TimeOsCallHandler();
      final result =
          (await handler.handle(fakeOsCall('datetime.now')))!
              as Map<String, Object?>;

      expect(result['__type'], 'datetime');
      expect(result['year'], isA<int>());
      expect(result['month'], isA<int>());
      expect(result['day'], isA<int>());
      expect(result['hour'], isA<int>());
      expect(result['minute'], isA<int>());
      expect(result['second'], isA<int>());
      expect(result['microsecond'], isA<int>());
      expect(result['offset_seconds'], isA<int>());
      expect(result['timezone_name'], isA<String>());
    });

    test('injected clock is used (frozen time)', () async {
      final frozen = DateTime(2026, 3, 15, 10, 30, 45, 123, 456);
      final handler = TimeOsCallHandler(clock: () => frozen);

      final date =
          (await handler.handle(fakeOsCall('date.today')))!
              as Map<String, Object?>;
      expect(date['year'], 2026);
      expect(date['month'], 3);
      expect(date['day'], 15);

      final dt =
          (await handler.handle(fakeOsCall('datetime.now')))!
              as Map<String, Object?>;
      expect(dt['year'], 2026);
      expect(dt['hour'], 10);
      expect(dt['minute'], 30);
      expect(dt['second'], 45);
    });

    test('unknown date/datetime operation throws', () {
      final handler = TimeOsCallHandler();

      expect(
        () => handler.handle(fakeOsCall('date.yesterday')),
        throwsUnsupportedError,
      );
      expect(
        () => handler.handle(fakeOsCall('datetime.utcnow')),
        throwsUnsupportedError,
      );
    });

    test('default clock uses DateTime.now', () async {
      final handler = TimeOsCallHandler();
      final before = DateTime.now();
      final result =
          (await handler.handle(fakeOsCall('datetime.now')))!
              as Map<String, Object?>;
      final after = DateTime.now();

      expect(result['year'], before.year);
      // Day should be within the range of the test run.
      expect(result['day'], greaterThanOrEqualTo(before.day));
      expect(result['day'], lessThanOrEqualTo(after.day));
    });

    test('timezone offset populated correctly', () async {
      final frozen = DateTime(2026, 6, 15, 12);
      final handler = TimeOsCallHandler(clock: () => frozen);

      final result =
          (await handler.handle(fakeOsCall('datetime.now')))!
              as Map<String, Object?>;
      expect(result['offset_seconds'], frozen.timeZoneOffset.inSeconds);
      expect(result['timezone_name'], frozen.timeZoneName);
    });
  });
}
