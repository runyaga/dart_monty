import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeMontySession session;
  late MontyRuntime runtime;

  setUp(() async {
    session = FakeMontySession();
    runtime = await startRuntimeWith(checkout: ({limits}) async => session);
    addTearDown(runtime.dispose);
  });

  group('shared settlement', () {
    test('accepts the next execute directly in a result callback', () async {
      session.willReturn(const MontyInt(1));
      final first = _executeWithDeferredCompletion(runtime, 'first');
      // ignore: prefer-async-await, exercise the immediate result callback.
      final next = first.result.then((value) {
        expect(value, const MontyInt(1));
        session.willReturn(const MontyInt(2));

        return runtime.execute('next').result;
      });

      expect(await next, const MontyInt(2));
      expect(session.feeds, ['first', 'next']);
    });

    test(
      'accepts the next execute directly in a result error callback',
      () async {
        session.willRaise('ZeroDivisionError');
        final first = _executeWithDeferredCompletion(runtime, 'first');
        // ignore: prefer-async-await, exercise the immediate error callback.
        final next = first.result.then<MontyValue>(
          (_) => fail('The first execution should fail'),
          onError: (Object error, StackTrace stackTrace) {
            expect(error, isA<MontyRuntimeError>());
            session.willReturn(const MontyInt(2));

            return runtime.execute('next').result;
          },
        );

        expect(await next, const MontyInt(2));
        expect(session.feeds, ['first', 'next']);
      },
    );

    test('accepts the next execute directly when events close', () async {
      session.willReturn(const MontyInt(1));
      final first = _executeWithDeferredCompletion(runtime, 'first');
      final next = Completer<MontyValue>();
      final subscription = first.events.listen(
        null,
        onDone: () {
          session.willReturn(const MontyInt(2));
          next.complete(runtime.execute('next').result);
        },
      );
      addTearDown(subscription.cancel);

      expect(await first.result, const MontyInt(1));
      expect(await next.future, const MontyInt(2));
      expect(session.feeds, ['first', 'next']);
    });

    test('rejected executions do not release the active run', () async {
      final gate = Completer<void>();
      session
        ..willHold(gate.future)
        ..willReturn(const MontyInt(1));
      final first = runtime.execute('first');
      final busy = throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Bridge is already executing',
        ),
      );

      // execute returns a handle; only its result fails. Settling that
      // rejection must not let a third execution take the first one's slot.
      await expectLater(runtime.execute('second').result, busy);
      await expectLater(runtime.execute('third').result, busy);
      gate.complete();

      expect(await first.result, const MontyInt(1));
      expect(session.feeds, ['first']);
    });
  });
}

/// Defers completion callbacks registered synchronously by execute by one
/// microtask. On the VM an async body's whenComplete can run inline before
/// listeners of a Completer it completed; other backends can defer it. This
/// forces the public result listener to run before that separate cleanup.
ExecutionHandle _executeWithDeferredCompletion(
  MontyRuntime runtime,
  String code,
) {
  var starting = true;

  return runZoned(
    () {
      try {
        return runtime.execute(code);
      } finally {
        starting = false;
      }
    },
    zoneSpecification: ZoneSpecification(
      registerCallback: <R>(self, parent, zone, callback) {
        final registered = parent.registerCallback(zone, callback);
        // Future.whenComplete registers its zero-argument action as dynamic.
        // Leave typed microtasks and later bridge callbacks untouched.
        if (!starting || R != dynamic) return registered;

        return () => Future<dynamic>.microtask(registered) as R;
      },
    ),
  );
}
