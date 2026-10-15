import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../_throwing_session.dart';

/// Tests of host-call dispatch from [MontyBridge.execute], which D1-3
/// rebuilds on core's feed (D1-2 built the run, OS-call and error events).
const _pending = 'd1-pending';

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
  group('deferred async error logging', tags: _pending, () {
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
  group('sync throw safety (#101)', tags: _pending, () {
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
          ),
        );

        // Sequence: Python calls explode, the host answers with an
        // exception, Python catches it and the feed ends.
        fake
          ..willCall('explode')
          ..willCatch()
          ..willReturn(const MontyNone());

        final events = await bridge.execute('explode()').toList();

        // Bridge should have emitted a BridgeRunFinished (not deadlocked).
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // The sync error should have been answered as an exception.
        final errors = _errorAnswers(fake);
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('sync boom'));
      },
    );
  });

  group('tool dispatch', tags: _pending, () {
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
          ..willCallOs('Path.read_text', args: [const MontyPath('/etc/passwd')])
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
          args: const [MontyPath('/tmp/out'), MontyString('data')],
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
        expect(() => bridge.execute('2'), throwsStateError);
        // Drain the first stream so cleanup happens.
        await stream.toList();
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

  group('argument validation error in _dispatchToolCall', tags: _pending, () {
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
  group('failure after an answer (#274)', tags: _pending, () {
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

    test('a failed execute does not free a later run when it ends', () async {
      final b =
          MontyBridge(session: fake, logger: BridgeLogger.silent)
              as SessionBridge;
      addTearDown(b.dispose);
      var wrapperCalls = 0;
      b.addStreamWrapper((code, stream) {
        if (wrapperCalls++ == 0) throw StateError('wrapper failure');
        return stream;
      });
      final gate = Completer<void>();
      fake
        ..willReturn(const MontyNone())
        ..willHold(gate.future)
        ..willReturn(const MontyNone());

      // The wrapper fails the first execute; its feed still runs.
      expect(() => b.execute('first'), throwsStateError);
      final second = b.execute('second').toList();
      // Let the first feed end while the second is held.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.feeds, contains('first'));

      expect(() => b.execute('third'), throwsStateError);

      gate.complete();
      expect((await second).last, isA<BridgeRunFinished>());
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
          ..willCallOs('Path.read_text', args: [const MontyPath('/etc/passwd')])
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
        ..willCallOs('Path.read_text', args: [const MontyPath('/missing')])
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
          args: [const MontyPath('/o'), const MontyString('d')],
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
