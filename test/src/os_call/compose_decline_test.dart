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

    test('an exhausted composer DECLINES, so composers nest', () async {
      // A composer is itself an OsCallHandler, and this codebase nests them:
      // coordinator.dart composes with another handler as `fallback`, and
      // `defaultOsHandler()` is itself a composer. If an exhausted composer
      // threw instead of declining, an inner one would abort the outer's
      // routing rather than letting it try the next candidate.
      final inner = composeOsHandlers({
        'date.': (operation, args, kwargs) async => 'inner-handled',
      });
      final outer = composeOsHandlers(
        {'os.': inner},
        fallback: (operation, args, kwargs) async => 'outer-fallback',
      );

      // `os.getenv` matches the outer's 'os.' prefix and is routed to `inner`,
      // which has no handler for it. That is a decline, not a failure, so the
      // outer's fallback must get a turn.
      expect(await outer('os.getenv', const [], null), 'outer-fallback');
    });

    test('declining with no fallback reports unhandled', () async {
      final os = composeOsHandlers({
        'date.': (operation, args, kwargs) async =>
            throw const OsCallNotHandledException('date.'),
      });

      // Not UnsupportedError: an unhandled op is a decline, which the runtime
      // renders as monty's own "not supported in this environment" rather than
      // a Dart-flavoured RuntimeError.
      await expectLater(
        os('date.today', const [], null),
        throwsA(isA<OsCallNotHandledException>()),
      );
    });
  });
}
