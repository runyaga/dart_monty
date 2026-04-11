import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall fakeOsCall(String op, [List<MontyValue> args = const []]) =>
      MontyOsCall(operationName: op, arguments: args);

  group('EnvOsCallHandler', () {
    late EnvOsCallHandler handler;

    setUp(() {
      handler = EnvOsCallHandler({'APP_ENV': 'production', 'DEBUG': '0'});
    });

    test('os.getenv returns value from provided map', () async {
      final result = await handler.handle(
        fakeOsCall('os.getenv', [const MontyString('APP_ENV')]),
      );

      expect(result, 'production');
    });

    test('os.getenv returns null for missing key', () async {
      final result = await handler.handle(
        fakeOsCall('os.getenv', [const MontyString('NONEXISTENT')]),
      );

      expect(result, isNull);
    });

    test('os.getenv returns default when key missing', () async {
      final result = await handler.handle(
        fakeOsCall('os.getenv', [
          const MontyString('NONEXISTENT'),
          const MontyString('fallback'),
        ]),
      );

      expect(result, 'fallback');
    });

    test('os.environ returns full map', () async {
      final result = await handler.handle(fakeOsCall('os.environ'));

      expect(result, isA<Map<String, String>>());
      final map = result! as Map<String, String>;
      expect(map['APP_ENV'], 'production');
      expect(map['DEBUG'], '0');
      expect(map.length, 2);
    });

    test('provided map does not leak host Platform.environment', () async {
      // The handler only exposes the injected map.
      final result = await handler.handle(fakeOsCall('os.environ'));
      final map = result! as Map<String, String>;

      // Should not contain typical host-only env vars.
      expect(map.containsKey('HOME'), isFalse);
      expect(map.containsKey('PATH'), isFalse);
    });

    test('unknown os.* operation throws', () {
      expect(
        () => handler.handle(fakeOsCall('os.listdir')),
        throwsUnsupportedError,
      );
    });
  });
}
