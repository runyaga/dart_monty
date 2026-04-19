import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('envHandler', () {
    late OsCallHandler handler;

    setUp(() {
      handler = envHandler(const {'APP_ENV': 'production', 'DEBUG': '0'});
    });

    test('os.getenv returns value from provided map', () async {
      final result = await handler('os.getenv', ['APP_ENV'], null);

      expect(result, 'production');
    });

    test('os.getenv returns null for missing key', () async {
      final result = await handler('os.getenv', ['NONEXISTENT'], null);

      expect(result, isNull);
    });

    test('os.getenv returns default when key missing', () async {
      final result = await handler(
        'os.getenv',
        ['NONEXISTENT', 'fallback'],
        null,
      );

      expect(result, 'fallback');
    });

    test('os.environ returns full map', () async {
      final result = await handler('os.environ', const [], null);

      expect(result, isA<Map<String, String>>());
      final map = result! as Map<String, String>;
      expect(map['APP_ENV'], 'production');
      expect(map['DEBUG'], '0');
      expect(map.length, 2);
    });

    test('provided map does not leak host Platform.environment', () async {
      // The handler only exposes the injected map.
      final result = await handler('os.environ', const [], null);
      final map = result! as Map<String, String>;

      // Should not contain typical host-only env vars.
      expect(map.containsKey('HOME'), isFalse);
      expect(map.containsKey('PATH'), isFalse);
    });

    test('unknown os.* operation throws', () {
      expect(
        () => handler('os.listdir', const [], null),
        throwsUnsupportedError,
      );
    });
  });
}
