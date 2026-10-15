import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
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

  Future<MontySession> checkout({ResourceLimits? limits}) async {
    checkoutLimits.add(limits);
    final fake = FakeMontySession();
    script[sessions.length]?.call(fake);
    final session = RecordingSession(fake);
    sessions.add(session);

    return session;
  }

  /// A shared-mode runtime with the host function `probe`, whose handler
  /// runs [body] with its context.
  Future<MontyRuntime> start(
    Future<Object?> Function(HostContext ctx) body, {
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

      return null;
    });

    await runtime.execute('probe()').result;

    expect(seen, const MontyTuple([MontyInt(1), MontyString('a')]));
  });

  test('binds inputs through the feed, each through fromDart', () async {
    script[1] = (sub) => sub.willReturn(const MontyInt(42));
    final runtime = await start(
      (ctx) => ctx.subExecute!('n * 2', inputs: {'n': 21, 's': 'x'}),
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
    expect(sessions[0].feeds.single.os, isNotNull);
    expect(sessions[0].feeds.single.externalLookup, contains('probe'));
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
      rootOpenInHandler = !sessions[0].closed;

      return null;
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

      return null;
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

          return null;
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
    unawaited(result.then((_) {}, onError: (_) {}));
    await entered.future;
    while (sessions.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }

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
    HostSubExecutor? seen = (_, {inputs}) async => const MontyNone();
    bridge.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'probe'),
        handler: (args, ctx) async {
          seen = ctx.subExecute;

          return null;
        },
      ),
    );

    await bridge.execute('probe()').toList();

    expect(seen, isNull);
  });

  test('a disposed runtime refuses a sub-execution', () async {
    final runtime = await startRuntimeWith(checkout: checkout);
    await runtime.dispose();

    await expectLater(runtime.subExecute('1'), throwsStateError);
    expect(sessions, hasLength(1));
  });
}
