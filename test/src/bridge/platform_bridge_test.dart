import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../_throwing_session.dart';

/// Tests of host-call dispatch from [MontyBridge.execute], which D1-3
/// rebuilds on core's feed (D1-2 built the run, OS-call and error events).

/// The [ExternalException]s the host answered with, in order.
List<ExternalException> _errorAnswers(FakeMontySession session) => [
  for (final a in session.answers)
    if (a.answer case final ExternalException e) e,
];

/// The values the host answered with, in order.
List<Object> _returnAnswers(FakeMontySession session) => [
  for (final a in session.answers)
    if (a.answer case ExternalReturnValue(:final value)) value,
];

/// [event] as one line: its type without the `Bridge` prefix and its ids
/// and payload, for comparing event sequences.
String _line(BridgeEvent event) => switch (event) {
  BridgeRunStarted(:final threadId, :final runId) =>
    'RunStarted $threadId $runId',
  BridgeCallStarted(:final callId) => 'CallStarted $callId',
  BridgeFunctionCallStart(:final callId, :final name) =>
    'FunctionCallStart $callId $name',
  BridgeFunctionCallArgs(:final callId, :final delta) =>
    'FunctionCallArgs $callId $delta',
  BridgeFunctionCallEnd(:final callId) => 'FunctionCallEnd $callId',
  BridgeFunctionEmit(:final callId, :final text) =>
    'FunctionEmit $callId $text',
  BridgeFunctionCallResult(:final callId, :final result) =>
    'FunctionCallResult $callId $result',
  BridgeCallFinished(:final callId) => 'CallFinished $callId',
  BridgeRunFinished() => 'RunFinished',
  BridgeRunError(:final message) => 'RunError $message',
  _ => '${event.runtimeType}',
};

/// A host function `fn` taking one integer `x`, answered by [handler].
HostFunction _fnX(
  HostFunctionHandler handler, {
  String name = 'fn',
  DispatchMode dispatch = DispatchMode.sync,
}) => HostFunction(
  schema: HostFunctionSchema(
    name: name,
    description: '',
    params: const [HostParam(name: 'x', type: HostParamType.integer)],
  ),
  handler: handler,
  dispatch: dispatch,
);

/// A runtime reference that only identifies itself.
final class _RuntimeRef implements MontyRuntimeRef {
  @override
  ExecutionHandle execute(
    String code, {
    OsHandler? os,
    Map<String, Object?>? inputs,
  }) => throw UnimplementedError('not used');

  @override
  void emitChildEvent(String childHandle, BridgeEvent event) {}

  @override
  List<HostFunctionSchema> get schemas => const [];
}

void main() {
  late FakeMontySession fake;
  late MontyBridge bridge;

  setUp(() {
    fake = FakeMontySession();
    bridge = MontyBridge(session: fake);
  });

  tearDown(() {
    bridge.dispose();
  });

  // P0: deferred host handler errors must not be swallowed silently.
  group('deferred async error logging', () {
    test('does not swallow deferred host handler errors', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'slow_fail',
            description: 'Fails asynchronously.',
          ),
          handler: (_, _) async {
            throw StateError('async kaboom');
          },
          dispatch: DispatchMode.future,
        ),
      );

      // Sequence: Python calls slow_fail (a future), then awaits it; the
      // failed future settles the await, and Python catches it.
      final id = fake.willCall('slow_fail');
      fake
        ..willAwait([id])
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('slow_fail()').toList();

      // The bridge should have completed (not deadlocked) and the error
      // should have been captured when the future settled.
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // The error was settled into the futures batch as an exception.
      final settled = [
        for (final a in fake.answers)
          if (a.batch != null && a.answer is ExternalException) a,
      ];
      expect(settled, hasLength(1));
      expect(settled.single.callId, id);
      expect(
        (settled.single.answer! as ExternalException).message,
        contains('async kaboom'),
      );
    });
  });

  // P0 safety fix: synchronous handler throw in futures path must not deadlock.
  group('sync throw safety (#101)', () {
    test(
      '_dispatchToolCallAsFuture catches synchronous handler throw',
      () async {
        // Register a host function whose handler throws synchronously
        // (before returning a Future).
        bridge.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'explode',
              description: 'Throws synchronously.',
            ),
            handler: (_, _) => throw StateError('sync boom'),
            dispatch: DispatchMode.future,
          ),
        );

        // Sequence: Python calls explode (a coroutine) and awaits it; the
        // failed coroutine settles the await, Python catches it and the
        // feed ends.
        final id = fake.willCall('explode');
        fake
          ..willAwait([id])
          ..willCatch()
          ..willReturn(const MontyNone());

        final events = await bridge.execute('await explode()').toList();

        // Bridge should have emitted a BridgeRunFinished (not deadlocked).
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // The sync throw settled the call's future as an exception.
        final settled = [
          for (final a in fake.answers)
            if (a.batch != null && a.answer is ExternalException) a,
        ];
        expect(settled, hasLength(1));
        expect(settled.single.callId, id);
        expect(
          (settled.single.answer! as ExternalException).message,
          contains('sync boom'),
        );
      },
    );
  });

  group('tool dispatch', () {
    test('calls the registered handler', () async {
      var called = false;
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_, _) async {
            called = true;
            return 'ok';
          },
        ),
      );

      fake
        ..willCall('fn')
        ..willReturn(const MontyNone());

      await bridge.execute('fn()').toList();
      expect(called, isTrue);
    });
  });

  group('MontyOsCall handling', () {
    test(
      'declines (the worker answers) when no handler registered',
      () async {
        fake
          ..willCallOs('Path.read_text', args: [MontyPath('/etc/passwd')])
          ..willCatch()
          ..willReturn(const MontyNone());

        final events = await bridge.execute('path.read_text()').toList();

        // Should have completed (not deadlocked).
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // With no handler the call is declined: the worker computes the
        // default (PermissionError naming the path), so the recorded answer
        // is not_handled (null), and the call emits no OS events.
        expect(fake.answers, hasLength(1));
        expect(fake.answers.single.answer, isNull);
        expect(events.whereType<BridgeOsCallStart>(), isEmpty);
        expect(events.whereType<BridgeOsCallResult>(), isEmpty);
      },
    );

    test(
      'invokes registered handler and resumes with result',
      () async {
        bridge.registerOs((operation, args, kwargs) async {
          if (operation == 'os.getenv') {
            return const MontyString('production');
          }
          return const MontyNone();
        });

        fake
          ..willCallOs(
            'os.getenv',
            args: [const MontyString('APP_ENV'), const MontyNone()],
          )
          ..willReturn(const MontyNone());

        final events = await bridge.execute('os.getenv("APP_ENV")').toList();

        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // Should have answered with the handler result.
        expect(_returnAnswers(fake), [const MontyString('production')]);

        // Should have emitted OsCall events.
        final starts = events.whereType<BridgeOsCallStart>().toList();
        expect(starts, hasLength(1));
        expect(starts.first.operationName, 'os.getenv');
        final results = events.whereType<BridgeOsCallResult>().toList();
        expect(results, hasLength(1));
        expect(results.first.result, 'production');
      },
    );

    test('handler exception resumes with error', () async {
      bridge.registerOs((operation, args, kwargs) async {
        throw StateError('disk on fire');
      });

      fake
        ..willCallOs(
          'Path.write_text',
          args: [MontyPath('/tmp/out'), const MontyString('data')],
        )
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('path.write_text()').toList();

      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // Should have answered with an exception carrying the text.
      final errors = _errorAnswers(fake);
      expect(errors, hasLength(1));
      expect(errors.first.message, contains('disk on fire'));

      // OsCallResult should contain the error.
      final results = events.whereType<BridgeOsCallResult>().toList();
      expect(results, hasLength(1));
      expect(results.first.result, contains('disk on fire'));
    });

    test('registerOs after dispose throws StateError', () {
      bridge.dispose();
      expect(
        () => bridge.registerOs((op, args, kwargs) async => const MontyNone()),
        throwsStateError,
      );
    });

    test('bridge.dispose() without handler registered does not throw', () {
      // No handler registered — dispose should be a clean no-op.
      bridge.dispose();

      // Calling again (already disposed) should not double-dispose.
      // registerOs should throw since disposed.
      expect(
        () => bridge.registerOs((op, args, kwargs) async => const MontyNone()),
        throwsStateError,
      );
    });
  });

  group('invokeHostFunction', () {
    test('calls the handler with the validated args', () async {
      Map<String, Object?>? capturedArgs;

      final b = MontyBridge(session: fake);
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'greet',
            description: '',
            params: [HostParam(name: 'who', type: HostParamType.string)],
          ),
          handler: (args, _) async {
            capturedArgs = args;

            return 'hello ${args['who']}';
          },
        ),
      );

      final result = await b.invokeHostFunction('greet', {'who': 'world'});

      expect(result, 'hello world');
      expect(capturedArgs, {'who': 'world'});
    });

    test('unknown function throws ArgumentError', () {
      expect(() => bridge.invokeHostFunction('nope', {}), throwsArgumentError);
    });

    test(
      'setOsHandler(null) clears; restoring via setOsHandler roundtrips',
      () async {
        Future<MontyValue> handlerA(
          String op,
          List<MontyValue> args,
          Map<String, MontyValue> kwargs,
        ) async => const MontyString('A');
        Future<MontyValue> handlerB(
          String op,
          List<MontyValue> args,
          Map<String, MontyValue> kwargs,
        ) async => const MontyString('B');

        final b = MontyBridge(session: fake) as SessionBridge;
        addTearDown(b.dispose);

        OsHandler? captured;
        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'peek', description: ''),
            handler: (_, ctx) async {
              captured = ctx.os;
              return null;
            },
          ),
        );

        // Initially null.
        await b.invokeHostFunction('peek', const {});
        expect(captured, isNull);

        b.registerOs(handlerA);
        await b.invokeHostFunction('peek', const {});
        expect(captured, same(handlerA));
        expect(b.currentOsHandler, same(handlerA));

        // Override to B, confirm swap visible to handlers.
        b.setOsHandler(handlerB);
        await b.invokeHostFunction('peek', const {});
        expect(captured, same(handlerB));

        // Restore A.
        b.setOsHandler(handlerA);
        await b.invokeHostFunction('peek', const {});
        expect(captured, same(handlerA));

        // Clear via null.
        b.setOsHandler(null);
        await b.invokeHostFunction('peek', const {});
        expect(captured, isNull);
        expect(b.currentOsHandler, isNull);
      },
    );

    test(
      'HostContext.os reflects currently-registered OsHandler',
      () async {
        OsHandler? capturedOs;
        bridge.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'peek_os', description: ''),
            handler: (_, ctx) async {
              capturedOs = ctx.os;
              return null;
            },
          ),
        );

        // Before registerOs: ctx.os is null.
        await bridge.invokeHostFunction('peek_os', const {});
        expect(capturedOs, isNull);

        // After registerOs: ctx.os is the registered handler.
        Future<MontyValue> handler(
          String op,
          List<MontyValue> args,
          Map<String, MontyValue> kwargs,
        ) async => const MontyString('ok');
        bridge.registerOs(handler);

        await bridge.invokeHostFunction('peek_os', const {});
        expect(capturedOs, same(handler));
      },
    );

    test('validates arguments via mapAndValidate', () {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'need_name',
            description: '',
            params: [HostParam(name: 'name', type: HostParamType.string)],
          ),
          handler: (_, _) async => null,
        ),
      );

      expect(
        () => bridge.invokeHostFunction('need_name', {}),
        throwsFormatException,
      );
    });

    test('rejects string for integer param', () {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'add',
            description: '',
            params: [HostParam(name: 'n', type: HostParamType.integer)],
          ),
          handler: (args, _) async => args['n'],
        ),
      );

      // Strings are no longer coerced — Monty maps Python int → Dart int
      // directly, so a string argument indicates a Python-side type error.
      expect(
        () => bridge.invokeHostFunction('add', {'n': '42'}),
        throwsFormatException,
      );
    });

    test('disposed bridge throws StateError', () {
      bridge.dispose();

      expect(() => bridge.invokeHostFunction('fn', {}), throwsStateError);
    });
  });

  group('invokeHostFunction onEvent', () {
    test('default omitted — events dropped, result still returned', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'streamer', description: ''),
          handler: (_, ctx) async {
            ctx
              ..emitText('progress 1')
              ..emitText('progress 2');
            return 'done';
          },
        ),
      );

      final result = await bridge.invokeHostFunction('streamer', const {});

      expect(result, 'done');
    });

    test('with onEvent — handler emissions surface in order', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'streamer', description: ''),
          handler: (_, ctx) async {
            ctx
              ..emitText('one')
              ..emitText('two');
            return 'done';
          },
        ),
      );

      final received = <BridgeEvent>[];
      final result = await bridge.invokeHostFunction(
        'streamer',
        const {},
        onEvent: received.add,
      );

      expect(result, 'done');
      expect(received, hasLength(2));
      expect(received[0], isA<BridgeFunctionEmit>());
      expect((received[0] as BridgeFunctionEmit).text, 'one');
      expect((received[1] as BridgeFunctionEmit).text, 'two');
      expect((received[0] as BridgeFunctionEmit).callId, 'streamer');
    });

    test(
      'with onEvent — custom BridgeEvent subtypes deliver verbatim',
      () async {
        bridge.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'os_caller',
              description: '',
            ),
            handler: (_, ctx) async {
              ctx.emit(
                const BridgeOsCallStart(
                  callId: 'os-1',
                  operationName: 'os.getenv',
                  argumentSummary: "'HOME'",
                ),
              );
              return null;
            },
          ),
        );

        final received = <BridgeEvent>[];
        await bridge.invokeHostFunction(
          'os_caller',
          const {},
          onEvent: received.add,
        );

        expect(received, hasLength(1));
        final event = received.single;
        expect(event, isA<BridgeOsCallStart>());
        expect((event as BridgeOsCallStart).operationName, 'os.getenv');
        expect(event.argumentSummary, "'HOME'");
      },
    );

    test('onEvent throws — swallowed, handler result returns', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'streamer', description: ''),
          handler: (_, ctx) async {
            ctx
              ..emitText('first')
              ..emitText('second');
            return 'done';
          },
        ),
      );

      var callCount = 0;
      final result = await bridge.invokeHostFunction(
        'streamer',
        const {},
        onEvent: (_) {
          callCount++;
          throw StateError('callback blew up');
        },
      );

      expect(result, 'done');
      expect(callCount, 2);
    });
  });

  group('error handling in _run', () {
    test('MontyError thrown during execution emits BridgeRunError', () async {
      // The worker dies: the feed throws MontyCrashedError (a MontyError).
      // A crash after a host-function answer is the #274 group's (D1-3).
      final b = MontyBridge(session: fake, logger: BridgeLogger.silent);
      addTearDown(b.dispose);

      fake.willCrash();

      final events = await b.execute('noop()').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.exception, isA<MontyCrashedError>());
    });

    test(
      'generic Object thrown during execution emits BridgeRunError',
      () async {
        final b = MontyBridge(
          session: ThrowingSession('unexpected string error'),
          logger: BridgeLogger.silent,
        );
        addTearDown(b.dispose);

        final events = await b.execute('noop()').toList();
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('unexpected string error'));
        expect(errors.first.exception, isNull);
      },
    );

    test(
      'MontyError mid-execution emits BridgeRunError (no printOutput)',
      () async {
        // A worker crash surfaces no print output.
        final b = MontyBridge(session: fake, logger: BridgeLogger.silent);
        addTearDown(b.dispose);

        fake.willCrash();

        final events = await b.execute('noop()').toList();
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.printOutput, isNull);
      },
    );
  });

  group('dispose safety', () {
    test('register after dispose throws StateError', () {
      bridge.dispose();
      expect(
        () => bridge.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_, _) async => null,
          ),
        ),
        throwsStateError,
      );
    });

    test('unregister after dispose throws StateError', () {
      bridge.dispose();
      expect(() => bridge.unregister('fn'), throwsStateError);
    });

    test('execute after dispose throws StateError', () {
      bridge.dispose();
      expect(() => bridge.execute('1 + 1'), throwsStateError);
    });

    test(
      'execute while already executing throws StateError',
      () async {
        // Start one execution.
        fake.willReturn(const MontyNone());
        final stream = bridge.execute('1');
        // Try starting another before the first completes.
        expect(
          () => bridge.execute('2'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Bridge is already executing',
            ),
          ),
        );
        // Drain the first stream so cleanup happens.
        await stream.toList();
        // The rejected code was never fed.
        expect(fake.feeds, ['1']);
      },
    );
  });

  group('unregister', () {
    test('removes a previously registered function', () {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'temp', description: ''),
          handler: (_, _) async => null,
        ),
      );
      expect(bridge.schemas.map((s) => s.name), contains('temp'));

      bridge.unregister('temp');
      expect(bridge.schemas.map((s) => s.name), isNot(contains('temp')));
    });

    test('unregister non-existent function does not throw', () {
      // Should be a no-op, not an error.
      expect(() => bridge.unregister('does_not_exist'), returnsNormally);
    });
  });

  group('unknown function handling', () {
    test('unknown function raises NameError in the sandbox', () async {
      // A name absent from the feed's externals is a NameError raised by
      // the worker; the host never answers it (D1-3).
      fake.willRaise(
        'NameError',
        message: "name 'not_registered' is not defined",
      );

      final events = await bridge.execute('not_registered()').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.exception?.exception.excType, 'NameError');
      expect(fake.answers, isEmpty);
    });
  });

  group('argument validation error in _dispatchToolCall', () {
    test('FormatException from mapAndValidate resumes with error', () async {
      final syncSession = FakeMontySession();
      final syncBridge = MontyBridge(
        session: syncSession,
        logger: BridgeLogger.silent,
      );
      addTearDown(syncBridge.dispose);

      syncBridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'need_param',
            description: '',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          handler: (_, _) async => null,
        ),
      );

      // Call without required param — mapAndValidate throws FormatException.
      syncSession
        ..willCall('need_param')
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await syncBridge.execute('need_param()').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(_errorAnswers(syncSession), hasLength(1));
    });

    test('FormatException in futures path resumes with error', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'need_param',
            description: '',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          handler: (_, _) async => null,
          dispatch: DispatchMode.future,
        ),
      );

      final id = fake.willCall('need_param');
      fake
        ..willAwait([id])
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('need_param()').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(_errorAnswers(fake), hasLength(1));
    });
  });

  // Regression: a failure after a host answer must not cause StateError
  // (#274). The worker dying after an answer is the 0.110 form of the old
  // "resume() throws" case.
  group('failure after an answer (#274)', () {
    test(
      'handler succeeds but the worker then dies — emits BridgeRunError',
      () async {
        final failBridge = MontyBridge(session: fake)
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'greet',
                description: 'Returns hello',
              ),
              handler: (_, _) async => 'hello',
            ),
          );

        fake
          ..willCall('greet')
          ..willCrash();

        final events = await failBridge.execute('greet()').toList();

        // Should get a BridgeRunError, NOT an uncaught StateError.
        final errors = events.whereType<BridgeRunError>().toList();
        expect(
          errors,
          hasLength(1),
          reason:
              'Expected BridgeRunError, got: '
              '${events.map((e) => e.runtimeType).toList()}',
        );
        expect(errors.first.exception, isA<MontyCrashedError>());
        expect(_returnAnswers(fake), [const MontyString('hello')]);

        failBridge.dispose();
      },
    );

    test(
      'multiple tool calls — a crash after the 3rd does not StateError',
      () async {
        final failBridge = MontyBridge(session: fake)
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'count',
                description: 'Returns incrementing number',
                params: [
                  HostParam(name: 'n', type: HostParamType.integer),
                ],
              ),
              handler: (args, _) async => args['n'],
            ),
          );

        fake
          ..willCall('count', kwargs: {'n': const MontyInt(1)})
          ..willCall('count', kwargs: {'n': const MontyInt(2)})
          ..willCall('count', kwargs: {'n': const MontyInt(3)})
          ..willCrash();

        final events = await failBridge.execute('code').toList();

        // Three calls answered, then the crash ends the run.
        final errors = events.whereType<BridgeRunError>().toList();
        expect(
          errors,
          hasLength(1),
          reason:
              'Expected BridgeRunError, got: '
              '${events.map((e) => e.runtimeType).toList()}',
        );
        expect(errors.first.exception, isA<MontyCrashedError>());

        // The tool calls should have result events.
        final results = events.whereType<BridgeFunctionCallResult>().toList();
        expect(results.length, greaterThanOrEqualTo(2));

        failBridge.dispose();
      },
    );
  });

  // D1-3: host calls on core's feed. Each registered function is a
  // MontyHostFunction in the feed's externalLookup, wrapped so its calls
  // emit dm's call events; a future-mode function is a core coroutine.
  group('host calls on the session (D1-3)', () {
    test('a call emits its events in order under one call id', () async {
      HostContext? seen;
      bridge.register(
        _fnX((args, ctx) async {
          seen = ctx;
          ctx.emitText('working');

          return 'x=${args['x']}';
        }),
      );
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(events.map(_line), [
        'RunStarted 0 1',
        'CallStarted 2',
        'FunctionCallStart 2 fn',
        'FunctionCallArgs 2 {"x":1}',
        'FunctionCallEnd 2',
        'FunctionEmit 2 working',
        'FunctionCallResult 2 x=1',
        'CallFinished 2',
        'RunFinished',
      ]);
      expect(seen!.executionId, '2');
      expect(seen!.parent, isNull);
      expect(_returnAnswers(fake), [const MontyString('x=1')]);
    });

    test('the Args event is the validated arguments: positional mapped, '
        'defaults filled', () async {
      Map<String, Object?>? got;
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fn',
            description: '',
            params: [
              HostParam(name: 'x', type: HostParamType.integer),
              HostParam(
                name: 'y',
                type: HostParamType.string,
                isRequired: false,
                defaultValue: 'dflt',
              ),
            ],
          ),
          handler: (args, _) async {
            got = args;

            return null;
          },
        ),
      );
      fake
        ..willCall('fn', args: [const MontyInt(1)])
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(1)').toList();

      expect(got, {'x': 1, 'y': 'dflt'});
      expect(
        events.whereType<BridgeFunctionCallArgs>().single.delta,
        '{"x":1,"y":"dflt"}',
      );
    });

    test('arguments JSON cannot encode are shown as a note, and the call '
        'goes on', () async {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      bridge.register(
        HostFunction(
          schema: HostFunctionSchema(
            name: 'fn',
            description: '',
            params: [
              const HostParam(name: 'x', type: HostParamType.integer),
              HostParam(
                name: 'y',
                type: HostParamType.list,
                isRequired: false,
                defaultValue: cyclic,
              ),
            ],
          ),
          handler: (_, _) async => 'ran',
        ),
      );
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(
        events.whereType<BridgeFunctionCallArgs>().single.delta,
        '"arguments not shown: JsonCyclicError"',
      );
      expect(events.map(_line).toList().sublist(4), [
        'FunctionCallEnd 2',
        'FunctionCallResult 2 ran',
        'CallFinished 2',
        'RunFinished',
      ]);
      expect(_returnAnswers(fake), [const MontyString('ran')]);
    });

    test('a value JSON has no form for is written with bounded work', () async {
      // A list shared at each of 30 levels: about 2^30 lists once
      // expanded. Under a non-string key JSON writes it as text.
      Object? shared = <Object?>[];
      for (var i = 0; i < 30; i++) {
        shared = <Object?>[shared, shared];
      }
      bridge.register(
        HostFunction(
          schema: HostFunctionSchema(
            name: 'fn',
            description: '',
            params: [
              const HostParam(name: 'x', type: HostParamType.integer),
              HostParam(
                name: 'y',
                type: HostParamType.map,
                isRequired: false,
                defaultValue: {0: shared},
              ),
            ],
          ),
          handler: (_, _) async => [
            1,
            'a',
            null,
            <Object?, Object?>{2: 3},
          ],
        ),
      );
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(
        events.whereType<BridgeFunctionCallArgs>().single.delta,
        startsWith('"arguments not shown: over '),
      );
      // A small result reads as its toString().
      expect(
        events.whereType<BridgeFunctionCallResult>().single.result,
        '[1, a, null, {2: 3}]',
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a deeply nested result is written without deep recursion', () async {
      Object? nested = <Object?>[];
      for (var i = 0; i < 100000; i++) {
        nested = <Object?>[nested];
      }
      bridge.register(_fnX((_, _) async => nested));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      final text = events.whereType<BridgeFunctionCallResult>().single.result;
      expect(text, '${'[' * 100001}${']' * 100001}');
      expect(events.last, isA<BridgeRunFinished>());
    });

    test('ids come from one counter across calls and runs', () async {
      bridge.register(_fnX((args, _) async => args['x']));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willCall('fn', kwargs: {'x': const MontyInt(2)})
        ..willReturn(const MontyNone());
      final first = await bridge.execute('fn(x=1); fn(x=2)').toList();
      fake.willReturn(const MontyNone());
      final second = await bridge.execute('pass').toList();

      expect(
        [
          for (final e in first)
            if (e is BridgeCallStarted) e.callId,
        ],
        ['2', '3'],
      );
      expect(_line(second.first), 'RunStarted 4 5');
    });

    test('a handler gets the runtime as its parent', () async {
      final runtime = _RuntimeRef();
      final b = SessionBridge(
        session: fake,
        runtime: runtime,
        logger: BridgeLogger.silent,
      );
      addTearDown(b.dispose);
      HostParentRef? parent;
      b.register(
        _fnX((_, ctx) async {
          parent = ctx.parent;

          return null;
        }),
      );
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      await b.execute('fn(x=1)').toList();

      expect(parent, same(runtime));
    });

    test('a null result is None and an empty result text', () async {
      bridge.register(_fnX((_, _) async => null));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(
        events.whereType<BridgeFunctionCallResult>().single.result,
        isEmpty,
      );
      expect(_returnAnswers(fake), [const MontyNone()]);
    });

    test('a result reaches Python through MontyValue.fromDart', () async {
      final result = {
        'a': [1, 2.5, null, true],
        'b': 'text',
      };
      bridge.register(_fnX((_, _) async => result));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willReturn(const MontyNone());

      await bridge.execute('fn(x=1)').toList();

      expect(_returnAnswers(fake), [MontyValue.fromDart(result)]);
    });

    test('a validation failure skips the handler and raises '
        'RuntimeError', () async {
      var called = false;
      bridge.register(
        _fnX((_, _) async {
          called = true;

          return null;
        }),
      );
      fake
        ..willCall('fn')
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn()').toList();

      expect(called, isFalse);
      final lines = events.map(_line).toList();
      expect(lines.sublist(1, 3), ['CallStarted 2', 'FunctionCallStart 2 fn']);
      expect(lines[3], startsWith('FunctionCallResult 2 Error: '));
      expect(lines[3], contains('Required parameter "x" is missing'));
      expect(lines.sublist(4), ['CallFinished 2', 'RunFinished']);
      final error = _errorAnswers(fake).single;
      expect(error.excType, 'RuntimeError');
      expect(error.message, contains('Required parameter "x" is missing'));
    });

    test('a handler throw raises RuntimeError with its text', () async {
      bridge.register(_fnX((_, _) async => throw StateError('boom')));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(events.map(_line).toList().sublist(5), [
        'FunctionCallResult 2 Error: Bad state: boom',
        'CallFinished 2',
        'RunFinished',
      ]);
      expect(
        _errorAnswers(fake),
        [const ExternalException('RuntimeError', 'Bad state: boom')],
      );
    });

    test("a handler's own ExternalException is raised as it is", () async {
      const raised = ExternalException('ValueError', 'bad value');
      bridge.register(_fnX((_, _) async => throw raised));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willCatch()
        ..willReturn(const MontyNone());

      await bridge.execute('fn(x=1)').toList();

      expect(_errorAnswers(fake), [raised]);
    });

    test('a host function cannot decline: OsCallNotHandledException is a '
        'RuntimeError', () async {
      bridge.register(
        _fnX((_, _) async => throw const OsCallNotHandledException()),
      );
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willCatch()
        ..willReturn(const MontyNone());

      await bridge.execute('fn(x=1)').toList();

      expect(_errorAnswers(fake), [
        const ExternalException('RuntimeError', 'OsCallNotHandledException()'),
      ]);
    });

    test('a value MontyValue.fromDart refuses raises RuntimeError', () async {
      bridge.register(_fnX((_, _) async => Object()));
      fake
        ..willCall('fn', kwargs: {'x': const MontyInt(1)})
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('fn(x=1)').toList();

      expect(_errorAnswers(fake).single.excType, 'RuntimeError');
      expect(
        events.whereType<BridgeFunctionCallResult>().single.result,
        startsWith('Error: '),
      );
    });

    test(
      'a sync-mode call is answered with its value at the call site',
      () async {
        bridge.register(_fnX((args, _) async => args['x']));
        fake
          ..willCall('fn', kwargs: {'x': const MontyInt(7)})
          ..willReturn(const MontyNone());

        await bridge.execute('fn(x=7)').toList();

        final answer = fake.answers.single;
        expect(answer.batch, isNull);
        expect(answer.answer, const ExternalReturnValue(MontyInt(7)));
      },
    );

    test('a future-mode call is a coroutine: settled through the futures '
        'protocol, its result events emitted when it completes', () async {
      final gate = Completer<Object?>();
      var started = false;
      bridge.register(
        _fnX((_, _) {
          started = true;

          return gate.future;
        }, dispatch: DispatchMode.future),
      );
      final id = fake.willCall('fn', kwargs: {'x': const MontyInt(1)});
      fake
        ..willAwait([id])
        ..willReturn(const MontyNone());

      final events = <BridgeEvent>[];
      final done = bridge.execute('await fn(x=1)').forEach(events.add);
      for (var i = 0; i < 100 && !started; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(started, isTrue);
      expect(events.whereType<BridgeFunctionCallResult>(), isEmpty);

      gate.complete('late');
      await done;

      expect(events.map(_line).toList().sublist(5), [
        'FunctionCallResult 2 late',
        'CallFinished 2',
        'RunFinished',
      ]);
      // The call is answered with a pending future at once, and settled
      // in a futures batch when the handler completes.
      final [pending, settled] = fake.answers;
      expect(pending.batch, isNull);
      expect(pending.answer, isA<ExternalFuture>());
      expect(settled.batch, isNotNull);
      expect(settled.callId, id);
      expect(settled.answer, const ExternalReturnValue(MontyString('late')));
    });

    test('a function with no handler on this backend is not passed to the '
        'feed', () async {
      bridge.register(
        const HostFunction(
          schema: HostFunctionSchema(name: 'absent', description: ''),
        ),
      );
      // The worker raises NameError for the name; the rest is dropped.
      fake
        ..willCall('absent')
        ..willReturn(const MontyNone());

      final events = await bridge.execute('absent()').toList();
      final error = events.whereType<BridgeRunError>().single;

      expect(error.exception?.exception.excType, 'NameError');
      // The session answers "not found" itself: no dm code runs, so no call
      // events are emitted.
      expect([for (final a in fake.answers) a.answer], [null]);
      expect(events.whereType<BridgeCallStarted>(), isEmpty);
    });
  });

  // D1-2: the bridge spine. One execute is one feedRun on the session; dm
  // builds the events itself.
  group('execute on the session (D1-2)', () {
    test(
      'starts with BridgeRunStarted and ends with BridgeRunFinished',
      () async {
        fake.willReturn(const MontyInt(7));

        final events = await bridge.execute('7').toList();

        expect(events.first, isA<BridgeRunStarted>());
        expect(events.last, isA<BridgeRunFinished>());
        expect(events, hasLength(2));
        final started = events.first as BridgeRunStarted;
        final finished = events.last as BridgeRunFinished;
        // Thread and run ids come from the bridge's counter, from '0'.
        expect(started.threadId, '0');
        expect(started.runId, '1');
        expect(finished.threadId, '0');
        expect(finished.runId, '1');
        expect(fake.feeds, ['7']);
      },
    );

    test(
      'BridgeRunFinished carries the MontyValue and its dartValue',
      () async {
        const result = MontyList([MontyInt(1), MontyString('a')]);
        fake.willReturn(result);

        final events = await bridge.execute('[1, "a"]').toList();
        final finished = events.whereType<BridgeRunFinished>().single;

        expect(finished.montyValue, result);
        expect(finished.value, [1, 'a']);
      },
    );

    test(
      'collects print output of both streams onto BridgeRunFinished',
      () async {
        fake
          ..willPrint('out ')
          ..willPrint('err', stream: 'stderr')
          ..willPrint('\n')
          ..willReturn(const MontyNone());

        final events = await bridge.execute('print("x")').toList();

        expect(
          events.whereType<BridgeRunFinished>().single.printOutput,
          'out err\n',
        );
        // No event per print fragment: only the two run events.
        expect(events, hasLength(2));
      },
    );

    test('a run without print output has a null printOutput', () async {
      fake.willReturn(const MontyNone());

      final events = await bridge.execute('None').toList();

      expect(events.whereType<BridgeRunFinished>().single.printOutput, isNull);
    });

    test('a Python failure ends the stream with one BridgeRunError', () async {
      fake
        ..willPrint('before\n')
        ..willRaise('ValueError', message: 'bad input');

      // The stream itself does not error.
      final events = await bridge.execute('raise ValueError()').toList();

      expect(events.first, isA<BridgeRunStarted>());
      expect(events.last, isA<BridgeRunError>());
      expect(events.whereType<BridgeRunError>(), hasLength(1));
      expect(events.whereType<BridgeRunFinished>(), isEmpty);
      final error = events.last as BridgeRunError;
      expect(error.exception, isA<MontyRuntimeError>());
      expect(error.exception!.exception.excType, 'ValueError');
      expect(error.message, 'ValueError: bad input');
      // Print text collected before the failure stays attached.
      expect(error.printOutput, 'before\n');
    });

    test('a worker crash ends the run with BridgeRunError', () async {
      fake.willCrash();

      final events = await bridge.execute('1').toList();

      final error = events.whereType<BridgeRunError>().single;
      expect(error.exception, isA<MontyCrashedError>());
      expect(events.last, same(error));
    });

    test('a failure that is not a MontyError fails the result with the '
        'original throw', () async {
      final original = StateError('session gone');
      final b = MontyBridge(
        session: ThrowingSession(original),
        logger: BridgeLogger.silent,
      );
      addTearDown(b.dispose);

      final events = await b.execute('1').toList();

      final error = events.whereType<BridgeRunError>().single;
      expect(error.exception, isNull);
      expect(error.message, original.toString());
      expect(() => extractBridgeResult(events), throwsA(same(original)));
    });

    test('logger, register(category:) and schemasByCategory', () {
      final log = _RecordingLogger();
      HostFunction fn(String name) => HostFunction(
        schema: HostFunctionSchema(name: name, description: ''),
        handler: (_, _) async => null,
      );
      final b = MontyBridge(session: FakeMontySession(), logger: log)
        ..register(fn('a'), category: 'files')
        ..register(fn('b'));
      addTearDown(b.dispose);

      expect(b.logger, same(log));
      expect(
        b.schemasByCategory.map(
          (k, v) => MapEntry(k, [for (final s in v) s.name]),
        ),
        {
          'files': ['a'],
          'uncategorized': ['b'],
        },
      );
    });

    test('constructing a bridge and reading schemas feeds nothing', () {
      final session = FakeMontySession();
      final b = MontyBridge(session: session)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'f', description: ''),
            handler: (_, _) async => null,
          ),
        );
      addTearDown(b.dispose);

      expect(b.schemas.map((s) => s.name), ['f']);
      expect(session.feeds, isEmpty);
    });

    test(
      'stream wrappers apply in order, the last registered outermost',
      () async {
        final b = MontyBridge(session: fake) as SessionBridge;
        addTearDown(b.dispose);
        final order = <String>[];
        b
          ..addStreamWrapper((code, stream) {
            order.add('first');
            return stream.map((e) {
              order.add('inner:${e.runtimeType}');
              return e;
            });
          })
          ..addStreamWrapper((code, stream) {
            order.add('second');
            return stream.map((e) {
              order.add('outer:${e.runtimeType}');
              return e;
            });
          });
        fake.willReturn(const MontyNone());

        await b.execute('None').toList();

        expect(order, [
          'first',
          'second',
          'inner:BridgeRunStarted',
          'outer:BridgeRunStarted',
          'inner:BridgeRunFinished',
          'outer:BridgeRunFinished',
        ]);
      },
    );

    test('a wrapper that throws feeds nothing and frees the bridge', () async {
      final b =
          MontyBridge(session: fake, logger: BridgeLogger.silent)
              as SessionBridge;
      addTearDown(b.dispose);
      var wrapperCalls = 0;
      b.addStreamWrapper((code, stream) {
        if (wrapperCalls++ == 0) throw StateError('wrapper failure');
        return stream;
      });
      fake.willReturn(const MontyInt(2));

      expect(() => b.execute('first'), throwsStateError);
      final events = await b.execute('second').toList();

      expect(fake.feeds, ['second']);
      expect(events.last, isA<BridgeRunFinished>());
    });

    test('events are logged as emitted, without a listener', () async {
      final log = _RecordingLogger();
      final b = MontyBridge(session: fake, logger: log);
      addTearDown(b.dispose);
      fake.willReturn(const MontyNone());

      // Nobody listens to the stream.
      b.execute('None');
      for (var i = 0; i < 50 && !log.messages.contains('run finished'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(log.messages, containsAllInOrder(['run started', 'run finished']));
    });

    test('BridgeRunError.exception is the MontyError the feed threw', () async {
      final error = await _montyError();
      final b = MontyBridge(
        session: ThrowingSession(error),
        logger: BridgeLogger.silent,
      );
      addTearDown(b.dispose);

      final events = await b.execute('1').toList();

      expect(events.whereType<BridgeRunError>().single.exception, same(error));
    });

    test('print text over the collector cap fails the run', () async {
      // core's default CollectString cap is 10 MiB; dm sets none of its own.
      fake
        ..willPrint('x' * (10 * 1024 * 1024 + 1))
        ..willReturn(const MontyNone());

      final events = await bridge.execute('print(...)').toList();

      expect(events.last, isA<BridgeRunError>());
    });

    test('print text at the collector cap is collected whole', () async {
      fake
        ..willPrint('x' * (10 * 1024 * 1024))
        ..willReturn(const MontyNone());

      final events = await bridge.execute('print(...)').toList();

      expect(
        (events.last as BridgeRunFinished).printOutput,
        hasLength(10 * 1024 * 1024),
      );
    });

    test('the bridge can run again after a run ends', () async {
      fake
        ..willReturn(const MontyInt(1))
        ..willReturn(const MontyInt(2));

      final first = await bridge.execute('1').toList();
      final second = await bridge.execute('2').toList();

      expect(first.whereType<BridgeRunFinished>().single.value, 1);
      expect(second.whereType<BridgeRunFinished>().single.value, 2);
      // The counter runs on across executions.
      expect((second.first as BridgeRunStarted).threadId, '2');
    });
  });

  group('OS calls on the session (D1-2)', () {
    test('a host-answered call emits OsCallStart then OsCallResult', () async {
      bridge.registerOs((name, args, kwargs) => const MontyString('v'));
      fake
        ..willCallOs(
          'os.getenv',
          args: [const MontyString('HOME'), const MontyNone()],
        )
        ..willReturn(const MontyNone());

      final events = await bridge.execute('os.getenv("HOME")').toList();

      final calls = events
          .where((e) => e is BridgeOsCallStart || e is BridgeOsCallResult)
          .toList();
      expect(calls, hasLength(2));
      final start = calls[0] as BridgeOsCallStart;
      final result = calls[1] as BridgeOsCallResult;
      expect(start.operationName, 'os.getenv');
      // Positional arguments' dartValues joined with ', '.
      expect(start.argumentSummary, 'HOME, null');
      expect(result.callId, start.callId);
      expect(result.result, 'v');
      expect(result.durationMs, isNotNull);
      expect(_returnAnswers(fake), [const MontyString('v')]);
      // The OS events sit between the run events.
      expect(events.first, isA<BridgeRunStarted>());
      expect(events.last, isA<BridgeRunFinished>());
    });

    test('a call with no arguments has a null argumentSummary', () async {
      bridge.registerOs((name, args, kwargs) => const MontyDict([]));
      fake
        ..willCallOs('os.environ')
        ..willReturn(const MontyNone());

      final events = await bridge.execute('os.environ').toList();

      expect(
        events.whereType<BridgeOsCallStart>().single.argumentSummary,
        isNull,
      );
    });

    test('a None answer reports an empty result', () async {
      bridge.registerOs((name, args, kwargs) => const MontyNone());
      fake
        ..willCallOs(
          'os.getenv',
          args: [const MontyString('X'), const MontyNone()],
        )
        ..willReturn(const MontyNone());

      final events = await bridge.execute('os.getenv("X")').toList();

      expect(events.whereType<BridgeOsCallResult>().single.result, '');
    });

    test(
      'an asynchronous handler is awaited and its result reported',
      () async {
        bridge.registerOs((name, args, kwargs) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return const MontyString('late');
        });
        fake
          ..willCallOs(
            'os.getenv',
            args: [const MontyString('X'), const MontyNone()],
          )
          ..willReturn(const MontyNone());

        final events = await bridge.execute('os.getenv("X")').toList();

        final result = events.whereType<BridgeOsCallResult>().single;
        expect(result.result, 'late');
        expect(result.durationMs, greaterThanOrEqualTo(15));
        expect(_returnAnswers(fake), [const MontyString('late')]);
      },
    );

    test(
      'a synchronous decline is passed on and reported as Declined',
      () async {
        bridge.registerOs(
          (name, args, kwargs) => throw const OsCallNotHandledException(),
        );
        fake
          ..willCallOs('Path.read_text', args: [MontyPath('/etc/passwd')])
          ..willCatch()
          ..willReturn(const MontyNone());

        final events = await bridge
            .execute('Path("/etc/passwd").read_text()')
            .toList();

        // Declined: the worker computes the default, so the answer is
        // not_handled (null).
        expect(fake.answers.single.answer, isNull);
        final result = events.whereType<BridgeOsCallResult>().single;
        expect(result.result, 'Declined');
        expect(
          result.callId,
          events.whereType<BridgeOsCallStart>().single.callId,
        );
      },
    );

    test('an ExternalException selects the Python type; result names its '
        'message', () async {
      bridge.registerOs(
        (name, args, kwargs) =>
            throw const ExternalException('FileNotFoundError', 'no such file'),
      );
      fake
        ..willCallOs('Path.read_text', args: [MontyPath('/missing')])
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge
          .execute('Path("/missing").read_text()')
          .toList();

      expect(_errorAnswers(fake), [
        const ExternalException('FileNotFoundError', 'no such file'),
      ]);
      expect(
        events.whereType<BridgeOsCallResult>().single.result,
        'Error: no such file',
      );
    });

    test('any other throw is reported as Error: <error>', () async {
      final boom = StateError('disk on fire');
      bridge.registerOs((name, args, kwargs) => throw boom);
      fake
        ..willCallOs(
          'Path.write_text',
          args: [MontyPath('/o'), const MontyString('d')],
        )
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('w()').toList();

      expect(
        events.whereType<BridgeOsCallResult>().single.result,
        'Error: $boom',
      );
      expect(_errorAnswers(fake).single.message, contains('disk on fire'));
    });

    test('with no handler, OS calls emit no events and are declined', () async {
      fake
        ..willCallOs(
          'os.getenv',
          args: [const MontyString('X'), const MontyNone()],
        )
        ..willCatch()
        ..willReturn(const MontyNone());

      final events = await bridge.execute('os.getenv("X")').toList();

      expect(events.whereType<BridgeOsCallStart>(), isEmpty);
      expect(events.whereType<BridgeOsCallResult>(), isEmpty);
      expect(fake.answers.single.answer, isNull);
      expect(events.last, isA<BridgeRunFinished>());
    });

    test('a synchronous answer reaches the session synchronously', () async {
      final probe = OsProbeSession('os.getenv', const [
        MontyString('X'),
        MontyNone(),
      ]);
      final b = MontyBridge(session: probe, logger: BridgeLogger.silent)
        ..registerOs((name, args, kwargs) => const MontyString('now'));
      addTearDown(b.dispose);

      await b.execute('os.getenv("X")').toList();

      expect(probe.returned, const MontyString('now'));
      expect(probe.returned, isNot(isA<Future<Object?>>()));
    });

    test(
      'a handler that settles after its feed ended reports nothing',
      () async {
        final pending = Completer<MontyValue>();
        final called = Completer<void>();
        final log = _RecordingLogger();
        final bridge = MontyBridge(session: fake, logger: log);
        addTearDown(bridge.dispose);
        bridge.registerOs((name, args, kwargs) {
          called.complete();
          return pending.future;
        });
        fake
          ..willCallOs(
            'os.getenv',
            args: [const MontyString('X'), const MontyNone()],
          )
          ..willReturn(const MontyNone());

        final events = <BridgeEvent>[];
        final done = bridge
            .execute('os.getenv("X")')
            .listen(events.add)
            .asFuture<void>();
        await called.future;
        // Closing the session ends the feed while the handler is pending.
        await fake.close();
        await done;
        final terminal = events.last;

        pending.complete(const MontyString('late'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(terminal, isA<BridgeRunError>());
        expect(events.last, same(terminal));
        expect(events.whereType<BridgeOsCallResult>(), isEmpty);
        // Nothing is reported or logged for the late answer.
        expect(log.messages, isNot(contains('os result')));
        expect(log.messages, isNot(contains('OS call handler error')));
      },
    );

    test('AttachContext.registerOs replaces the handler set before', () async {
      (bridge as AttachContext)
        ..registerOs((name, args, kwargs) => const MontyString('A'))
        ..registerOs((name, args, kwargs) => const MontyString('B'));
      fake
        ..willCallOs(
          'os.getenv',
          args: [const MontyString('X'), const MontyNone()],
        )
        ..willReturn(const MontyNone());

      await bridge.execute('os.getenv("X")').toList();

      expect(_returnAnswers(fake), [const MontyString('B')]);
    });
  });
}

/// A [BridgeLogger] that records each message.
final class _RecordingLogger implements BridgeLogger {
  final List<String> messages = [];

  @override
  void trace(String message, {Map<String, Object?>? attributes}) =>
      messages.add(message);

  @override
  void debug(String message, {Map<String, Object?>? attributes}) =>
      messages.add(message);

  @override
  void info(String message, {Map<String, Object?>? attributes}) =>
      messages.add(message);

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages.add(message);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages.add(message);

  @override
  BridgeLogger child(String name) => this;

  @override
  void close() {}
}

/// A real [MontyError], raised by a scripted fake session.
Future<MontyError> _montyError() async {
  final session = FakeMontySession()..willRaise('ValueError', message: 'v');
  try {
    await session.feedRun('raise ValueError()');
  } on MontyError catch (e) {
    return e;
  }
  throw StateError('the scripted feed did not raise');
}
