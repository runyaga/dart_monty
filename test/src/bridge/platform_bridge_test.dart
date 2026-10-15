import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

/// Tests that drive [MontyBridge.execute], which D1-2 (events, OS calls,
/// errors) and D1-3 (host-call dispatch) rebuild on core's feed.
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
      tags: _pending,
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
        // is not_handled (null). Which events a worker-answered call emits
        // is D1-2's (REQ-events-and-print).
        expect(fake.answers, hasLength(1));
        expect(fake.answers.single.answer, isNull);
      },
    );

    test(
      'invokes registered handler and resumes with result',
      tags: _pending,
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

    test('handler exception resumes with error', tags: _pending, () async {
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

  group('error handling in _run', tags: _pending, () {
    test('MontyError thrown during execution emits BridgeRunError', () async {
      // The worker dies after the host answers noop: the feed throws
      // MontyCrashedError (a MontyError).
      final b = MontyBridge(session: fake, logger: BridgeLogger.silent);
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'noop', description: ''),
          handler: (_, _) async => null,
        ),
      );
      fake
        ..willCall('noop')
        ..willCrash();

      final events = await b.execute('noop()').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.exception, isA<MontyCrashedError>());
    });

    test(
      'generic Object thrown during execution emits BridgeRunError',
      () async {
        final b = MontyBridge(
          session: _ThrowingSession('unexpected string error'),
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

        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'noop', description: ''),
            handler: (_, _) async => null,
          ),
        );
        fake
          ..willCall('noop')
          ..willCrash();

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
      tags: _pending,
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

  group('unknown function handling', tags: _pending, () {
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
}

/// A session whose feeds throw [error], which is not a [MontyError].
final class _ThrowingSession implements MontySession {
  _ThrowingSession(this.error);

  final Object error;

  @override
  int? get workerPid => null;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, Object>? inputs,
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
  }

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, Object>? inputs,
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) async {
    // ignore: only_throw_errors – the test needs a non-Exception throw.
    throw error;
  }

  @override
  Future<void> loadSession(Uint8List state) async {}

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    Map<
      String,
      FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
    >?
    externals,
    FutureOr<void> Function(String stream, String text)? printCallback,
    OsHandler? os,
  }) async => throw UnsupportedError('loadSnapshot');

  @override
  Future<Uint8List> dump() async => Uint8List(0);

  @override
  Future<void> close() async {}
}
