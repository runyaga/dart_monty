import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

// `OsCallNotHandledException` exists so a handler can DECLINE an operation it
// does not implement — core's doc: "Thrown by an `OsCallHandler` to decline
// the requested OS call." For declining to mean anything, the composer must
// treat it as "not mine" and keep routing, rather than let it escape.
void main() {
  group('composeOsHandlers treats a decline as not-handled', () {
    test('a declining prefix handler falls through to the fallback', () async {
      final os = composeOsHandlers(
        {
          'date.': (operation, args, kwargs) async =>
              throw const OsCallNotHandledException('date.'),
        },
        fallback: (operation, args, kwargs) async => 'from-fallback',
      );

      expect(await os('date.today', const [], null), 'from-fallback');
    });

    test('a shorter matching prefix gets a turn after a decline', () async {
      final os = composeOsHandlers({
        // Longest prefix wins first, then declines.
        'date.today': (operation, args, kwargs) async =>
            throw const OsCallNotHandledException('date.today'),
        'date.': (operation, args, kwargs) async => 'from-shorter-prefix',
      });

      expect(await os('date.today', const [], null), 'from-shorter-prefix');
    });

    test('a genuine error is NOT swallowed', () async {
      final os = composeOsHandlers(
        {
          'date.': (operation, args, kwargs) async =>
              throw StateError('a real bug'),
        },
        fallback: (operation, args, kwargs) async => 'from-fallback',
      );

      await expectLater(
        os('date.today', const [], null),
        throwsA(isA<StateError>()),
      );
    });

    test('declining with no fallback still reports unhandled', () async {
      final os = composeOsHandlers({
        'date.': (operation, args, kwargs) async =>
            throw const OsCallNotHandledException('date.'),
      });

      await expectLater(
        os('date.today', const [], null),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
