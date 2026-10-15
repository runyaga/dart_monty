import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_os_call.dart';

// `OsCallNotHandledException` exists so a handler can DECLINE an operation it
// does not implement. Core honours only a SYNCHRONOUS throw (a returned
// `Future` that fails with it raises `TypeError`), so the composer must treat a
// sync decline as "not mine", keep routing, and decline synchronously itself.
void main() {
  OsHandler declining() =>
      (operation, args, kwargs) => throw const OsCallNotHandledException();
  OsHandler answering(String tag) =>
      (operation, args, kwargs) => MontyString(tag);

  group('composeOsHandlers treats a decline as not-handled', () {
    test('a declining prefix handler falls through to the fallback', () {
      final os = composeOsHandlers(
        {'date.': declining()},
        fallback: answering('from-fallback'),
      );

      expect(rawCall(os, 'date.today'), const MontyString('from-fallback'));
    });

    test('a shorter matching prefix gets a turn after a decline', () {
      final os = composeOsHandlers({
        // Longest prefix wins first, then declines.
        'date.today': declining(),
        'date.': answering('from-shorter-prefix'),
      });

      expect(
        rawCall(os, 'date.today'),
        const MontyString('from-shorter-prefix'),
      );
    });

    test('a declining open() falls through to prefix matching', () {
      final os = composeOsHandlers({
        'Path.': declining(),
        'open': answering('from-open-prefix'),
      });

      expect(rawCall(os, 'open'), const MontyString('from-open-prefix'));
    });

    test('a genuine error is NOT swallowed', () {
      final os = composeOsHandlers(
        {'date.': (operation, args, kwargs) => throw StateError('a real bug')},
        fallback: answering('from-fallback'),
      );

      expect(() => rawCall(os, 'date.today'), throwsA(isA<StateError>()));
    });

    test('an exhausted composer DECLINES, so composers nest', () {
      // A composer is itself an OsHandler, and this codebase nests them:
      // coordinator.dart composes with another handler as `fallback`, and
      // `defaultOsHandler()` is itself a composer. If an exhausted composer
      // threw instead of declining, an inner one would abort the outer's
      // routing rather than letting it try the next candidate.
      final inner = composeOsHandlers({'date.': answering('inner-handled')});
      final outer = composeOsHandlers(
        {'os.': inner},
        fallback: answering('outer-fallback'),
      );

      // `os.getenv` matches the outer's 'os.' prefix and is routed to `inner`,
      // which has no handler for it. That is a decline, not a failure, so the
      // outer's fallback must get a turn.
      expect(rawCall(outer, 'os.getenv'), const MontyString('outer-fallback'));
    });

    test('declining with no fallback throws the decline synchronously', () {
      final os = composeOsHandlers({'date.': declining()});

      expectSyncDecline(() => rawCall(os, 'date.today'));
    });

    test('an operation no prefix matches declines synchronously', () {
      final os = composeOsHandlers({'Path.': answering('fs')});

      expectSyncDecline(() => rawCall(os, 'socket.connect'));
      expectSyncDecline(() => rawCall(composeOsHandlers({}), 'Path.exists'));
    });

    test('a sync answer stays a MontyValue, not a Future', () {
      final os = composeOsHandlers({'Path.': answering('fs')});

      expect(rawCall(os, 'Path.exists'), isA<MontyString>());
    });

    test('a Future answer passes through unchanged', () async {
      final os = composeOsHandlers({
        'Path.': (operation, args, kwargs) async => const MontyString('later'),
      });

      final result = rawCall(os, 'Path.exists');
      expect(result, isA<Future<MontyValue>>());
      expect(await result, const MontyString('later'));
    });

    test('a Future that fails with the decline does NOT decline', () async {
      final os = composeOsHandlers(
        {
          'date.': (operation, args, kwargs) async =>
              throw const OsCallNotHandledException(),
        },
        fallback: answering('from-fallback'),
      );

      // Not a sync throw: the fallback gets no turn, the failure reaches the
      // caller as a failed Future, which core reports as a TypeError.
      final result = rawCall(os, 'date.today');
      expect(result, isA<Future<MontyValue>>());
      await expectLater(result, throwsA(isA<OsCallNotHandledException>()));
    });
  });

  group('OsCallNotHandledException', () {
    test('is const and takes no operation name', () {
      const a = OsCallNotHandledException();
      const b = OsCallNotHandledException();

      expect(identical(a, b), isTrue);
    });
  });
}
