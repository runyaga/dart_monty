import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        ExternalReturnValue,
        ExternalSettledResult,
        MontyInt,
        MontyString,
        MontyTuple;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../_recording_session.dart';

/// `HostContext.subExecute` on a runtime: a second checkout from the
/// runtime's pool, with the inputs bound by the feed and nothing else.
/// The sessions are core's scripted `FakeMontySession`s, each wrapped to
/// record its feeds, supplied through the runtime's test hook.
void main() {
  late List<RecordingSession> sessions;
  late List<ResourceLimits?> checkoutLimits;
  // Scripts the n-th session checked out (0 is the runtime's own).
  late Map<int, void Function(FakeMontySession)> script;

  Future<MontySession> checkout({ResourceLimits? limits}) {
    checkoutLimits.add(limits);
    final fake = FakeMontySession();
    script[sessions.length]?.call(fake);
    final session = RecordingSession(fake);
    sessions.add(session);

    return Future.value(session);
  }

  /// A shared-mode runtime with the host function `probe`, whose handler
  /// runs [body] with its context.
  Future<MontyRuntime> start(
    Future<MontyValue> Function(HostContext ctx) body, {
    OsHandler? os,
  }) async {
    final runtime = await startRuntimeWith(checkout: checkout, os: os)
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'probe'),
          handler: (args, ctx) => body(ctx),
        ),
      );
    addTearDown(runtime.dispose);

    return runtime;
  }

  /// The values the root session's host calls were answered with.
  List<ExternalSettledResult> rootAnswers() => [
    for (final a in (sessions.first.inner as FakeMontySession).answers)
      if (a.answer case final ExternalSettledResult r) r,
  ];

  setUp(() {
    sessions = [];
    checkoutLimits = [];
    script = {
      0: (root) => root
        ..willCall('probe')
        ..willReturn(const MontyNone()),
    };
  });

  test('runs on a second checkout, with default limits', () async {
    script[1] = (sub) => sub.willReturn(const MontyInt(42));
    final runtime = await start((ctx) => ctx.subExecute!('6 * 7'));

    await runtime.execute('probe()').result;

    expect(sessions, hasLength(2));
    expect(checkoutLimits, [null, null]);
    expect(sessions[1].feeds.single.code, '6 * 7');
  });

  test("returns the sub-script's MontyValue to the handler", () async {
    script[1] = (sub) => sub.willReturn(
      const MontyTuple([MontyInt(1), MontyString('a')]),
    );
    Object? seen;
    final runtime = await start((ctx) async {
      seen = await ctx.subExecute!('(1, "a")');

      return const MontyNone();
    });

    await runtime.execute('probe()').result;

    expect(seen, const MontyTuple([MontyInt(1), MontyString('a')]));
  });

  test('binds inputs through the feed, each through fromDart', () async {
    script[1] = (sub) => sub.willReturn(const MontyInt(42));
    final runtime = await start(
      (ctx) => ctx.subExecute!(
        'n * 2',
        inputs: {'n': const MontyInt(21), 's': const MontyString('x')},
      ),
    );

    await runtime.execute('probe()').result;

    expect(sessions[1].feeds.single.inputs, {
      'n': const MontyInt(21),
      's': const MontyString('x'),
    });
  });

  test('passes no OS handler and no host functions', () async {
    script[1] = (sub) => sub.willReturn(const MontyNone());
    final runtime = await start(
      (ctx) => ctx.subExecute!('1'),
      os: (name, args, kwargs) async => const MontyNone(),
    );

    await runtime.execute('probe()').result;

    // The root feed has both; the sub-execution's has neither.
    expect(sessions.first.feeds.single.os, isNotNull);
    expect(sessions.first.feeds.single.externalLookup, contains('probe'));
    expect(sessions[1].feeds.single.os, isNull);
    expect(sessions[1].feeds.single.externalLookup, isNull);
  });

  test('closes its session and leaves the caller its own', () async {
    script[1] = (sub) => sub.willReturn(const MontyNone());
    var subClosedInHandler = false;
    var rootOpenInHandler = false;
    final runtime = await start((ctx) async {
      await ctx.subExecute!('1');
      subClosedInHandler = sessions[1].closed;
      rootOpenInHandler = !sessions.first.closed;

      return const MontyNone();
    });

    await runtime.execute('probe()').result;

    expect(subClosedInHandler, isTrue);
    expect(rootOpenInHandler, isTrue);
  });

  test("fails with the sub-script's MontyError", () async {
    script[1] = (sub) => sub.willRaise('ValueError', message: 'bad input');
    Object? caught;
    final runtime = await start((ctx) async {
      try {
        await ctx.subExecute!('raise ValueError("bad input")');
      } on Object catch (e) {
        caught = e;
      }

      return const MontyNone();
    });

    await runtime.execute('probe()').result;

    expect(caught, isA<MontyError>());
    final error = caught! as MontyError;
    expect(error.exception.excType, 'ValueError');
    expect(error.exception.message, 'bad input');
    expect(sessions[1].closed, isTrue);
  });

  test('a failed checkout fails subExecute with its error', () async {
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        if (sessions.isNotEmpty) {
          throw TimeoutException('no free worker', Duration.zero);
        }

        return checkout(limits: limits);
      },
    );
    addTearDown(runtime.dispose);
    Object? caught;
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'probe'),
        handler: (args, ctx) async {
          try {
            await ctx.subExecute!('1');
          } on Object catch (e) {
            caught = e;
          }

          return const MontyNone();
        },
      ),
    );

    await runtime.execute('probe()').result;

    expect(caught, isA<TimeoutException>());
  });

  test('dispose closes a sub-execution in progress', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    script[1] = (sub) => sub
      ..willHold(gate.future)
      ..willReturn(const MontyNone());
    final runtime = await start((ctx) {
      entered.complete();

      return ctx.subExecute!('1');
    });
    final result = runtime.execute('probe()').result;
    unawaited(() async {
      try {
        // The root result is not asserted; session state is.
        await result;
      } on Object {
        // The disposed sub may fail the root; that is not asserted here.
      }
    }());
    await entered.future;
    // Wait for the sub-execution's feed to start, so dispose meets it
    // running rather than just checked out.
    for (var i = 0; i < 1000 && sessions.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < 1000 && sessions[1].feeds.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sessions[1].feeds, hasLength(1));

    await runtime.dispose();

    expect(sessions[1].closed, isTrue);
    gate.complete();
  });

  test('every Python call of a handler gets the sub-executor', () async {
    script[1] = (sub) => sub.willReturn(const MontyInt(1));
    final runtime = await start((ctx) => ctx.subExecute!('1'));

    await runtime.execute('probe()').result;

    expect(rootAnswers().single, isA<ExternalReturnValue>());
  });

  test('a bare-session bridge gives handlers no sub-executor', () async {
    final fake = FakeMontySession()
      ..willCall('probe')
      ..willReturn(const MontyNone());
    final bridge = SessionBridge(session: fake);
    addTearDown(bridge.dispose);
    HostSubExecutor? seen = (_, {inputs}) => Future.value(const MontyNone());
    bridge.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'probe'),
        handler: (args, ctx) async {
          seen = ctx.subExecute;

          return const MontyNone();
        },
      ),
    );

    await bridge.execute('probe()').toList();

    expect(seen, isNull);
  });

  test('a checkout that arrives after dispose is closed, and fails', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    Object? caught;
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        if (sessions.isNotEmpty) {
          entered.complete();
          await gate.future;
        }

        return checkout(limits: limits);
      },
    );
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'probe'),
        handler: (args, ctx) async {
          try {
            await ctx.subExecute!('1');
          } on Object catch (e) {
            caught = e;
          }

          return const MontyNone();
        },
      ),
    );
    final result = runtime.execute('probe()').result;
    unawaited(() async {
      try {
        // The root result is not asserted; caught carries the failure.
        await result;
      } on Object {
        // Not expected to fire: the handler catches the sub failure itself.
      }
    }());
    await entered.future;

    await runtime.dispose();
    gate.complete();
    for (var i = 0; i < 1000 && caught == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(caught, isA<StateError>());
    expect(sessions[1].closed, isTrue);
    expect(sessions[1].feeds, isEmpty);
  });

  group('the caller ends first', () {
    /// Polls one event-loop turn at a time until [condition] holds.
    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 1000 && !condition(); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(condition(), isTrue);
    }

    /// A runtime whose `probe` runs a sub-execution held by [feedGate]
    /// (when given) after a checkout held by [checkoutGate] (when given);
    /// [caught] receives what the sub-execution threw.
    Future<(MontyRuntime, ExecutionHandle)> holdSub({
      required void Function(Object) caught,
      Completer<void>? checkoutGate,
      Completer<void>? feedGate,
    }) async {
      if (feedGate != null) {
        script[1] = (sub) => sub
          ..willHold(feedGate.future)
          ..willReturn(const MontyNone());
      }
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async {
          if (sessions.isNotEmpty) await checkoutGate?.future;

          return checkout(limits: limits);
        },
      );
      addTearDown(runtime.dispose);
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'probe'),
          handler: (args, ctx) async {
            try {
              await ctx.subExecute!('1');
            } on Object catch (e) {
              caught(e);
            }

            return const MontyNone();
          },
        ),
      );
      final handle = runtime.execute('probe()');
      unawaited(() async {
        try {
          // The root result is not asserted; caught receives the failure.
          await handle.result;
        } on Object {
          // Not expected to fire: the handler routes errors to caught.
        }
      }());

      return (runtime, handle);
    }

    test('dispose closes a sub-execution started by invoke', () async {
      final gate = Completer<void>();
      addTearDown(() => gate.isCompleted ? null : gate.complete());
      script[0] = (_) {
        // The invoke path runs no code on the root session.
      };
      script[1] = (sub) => sub
        ..willHold(gate.future)
        ..willReturn(const MontyNone());
      final runtime = await start((ctx) => ctx.subExecute!('1'));
      final invoked = runtime.invoke('probe', {});
      unawaited(() async {
        try {
          // The invoke result is not asserted; session state is.
          await invoked;
        } on Object {
          // The disposed sub may fail the invoke; that is not asserted here.
        }
      }());
      await until(() => sessions.length > 1 && sessions[1].feeds.isNotEmpty);

      await runtime.dispose();

      expect(sessions[1].closed, isTrue);
    });

    for (final viaInvoke in [false, true]) {
      test(
        'a handler that calls subExecute after clearState is refused '
        '(${viaInvoke ? 'invoke' : 'execute'})',
        () async {
          final resume = Completer<void>();
          final paused = Completer<void>();
          Object? error;
          script[0] = viaInvoke
              ? (_) {
                  // The invoke path runs no code on the root session.
                }
              : (root) => root
                  ..willCall('probe')
                  ..willReturn(const MontyNone());
          final runtime = await start((ctx) async {
            paused.complete();
            await resume.future;
            try {
              await ctx.subExecute!('1');
            } on Object catch (e) {
              error = e;
            }

            return const MontyNone();
          });
          final call = viaInvoke
              ? runtime.invoke('probe', {})
              : runtime.execute('probe()').result;
          unawaited(() async {
            try {
              // The call's value is not asserted; error carries the refusal.
              await call;
            } on Object {
              // Not expected to fire: the handler catches the refusal itself.
            }
          }());
          await paused.future;

          await runtime.clearState();
          final before = sessions.length;
          resume.complete();
          await until(() => error != null);

          expect(error, isA<StateError>());
          expect(sessions, hasLength(before));
        },
      );
    }

    test('a cancel closes a running sub-execution', () async {
      final gate = Completer<void>();
      addTearDown(() => gate.isCompleted ? null : gate.complete());
      Object? error;
      final (_, handle) = await holdSub(
        feedGate: gate,
        caught: (e) => error = e,
      );
      await until(() => sessions.length > 1 && sessions[1].feeds.isNotEmpty);

      await handle.cancel();

      await until(() => sessions[1].closed);
      await until(() => error != null);
    });

    test('a checkout that arrives after a cancel is closed unfed', () async {
      final gate = Completer<void>();
      Object? error;
      final (_, handle) = await holdSub(
        checkoutGate: gate,
        caught: (e) => error = e,
      );
      // The root's checkout is done; the sub-execution's waits on the gate.
      await until(
        () => (sessions.first.inner as FakeMontySession).feeds.isNotEmpty,
      );
      await Future<void>.delayed(Duration.zero);

      await handle.cancel();
      gate.complete();

      await until(() => error != null);
      expect(error, isA<StateError>());
      expect(sessions[1].closed, isTrue);
      expect(sessions[1].feeds, isEmpty);
    });

    test('clearState closes a running sub-execution', () async {
      final gate = Completer<void>();
      addTearDown(() => gate.isCompleted ? null : gate.complete());
      final (runtime, _) = await holdSub(
        feedGate: gate,
        caught: (_) {
          // The sub error is not asserted; the session's closing is.
        },
      );
      await until(() => sessions.length > 1 && sessions[1].feeds.isNotEmpty);

      final clearing = runtime.clearState();

      await until(() => sessions[1].closed);
      gate.complete();
      await clearing;
    });

    test('a checkout that arrives after clearState is closed unfed', () async {
      final gate = Completer<void>();
      Object? error;
      final (runtime, _) = await holdSub(
        checkoutGate: gate,
        caught: (e) => error = e,
      );
      await until(
        () => (sessions.first.inner as FakeMontySession).feeds.isNotEmpty,
      );
      await Future<void>.delayed(Duration.zero);

      final clearing = runtime.clearState();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await clearing;

      await until(() => error != null);
      expect(error, isA<StateError>());
      final sub = sessions.where((s) => s.feeds.isEmpty && s.closed);
      expect(sub, isNotEmpty);
    });
  });
}
