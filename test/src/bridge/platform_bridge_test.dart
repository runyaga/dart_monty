import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  late MockMontyPlatform mock;
  late MontyBridge bridge;

  setUp(() {
    mock = MockMontyPlatform();
    bridge = MontyBridge(platform: mock);
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

      // Sequence: start -> Pending(slow_fail) -> resumeAsFuture ->
      // ResolveFutures([1]) -> Complete
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'slow_fail',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('slow_fail()').toList();

      // The bridge should have completed (not deadlocked) and the error
      // should have been captured during future resolution.
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // The error was sent through resolveFutures with an errors map.
      expect(mock.history.resolveFuturesErrorsList, hasLength(1));
      final errors = mock.history.resolveFuturesErrorsList.first;
      expect(errors, isNotNull);
      expect(errors![1], contains('async kaboom'));
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
          ),
        );

        // Sequence: start -> Pending(explode) -> resumeWithError -> Complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'explode',
              arguments: [],
              callId: 1,
            ),
          )
          // After the sync throw, bridge calls resumeWithError which yields:
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final events = await bridge.execute('explode()').toList();

        // Bridge should have emitted a BridgeRunFinished (not deadlocked).
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // The sync error should have been sent via resumeWithError.
        expect(mock.history.resumeErrorMessages, hasLength(1));
        expect(mock.history.resumeErrorMessages.first, contains('sync boom'));
      },
    );
  });

  group('MontyInterceptor', () {
    test('interceptor is called on tool dispatch', () async {
      final log = <String>[];

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          log.add('before:$name');
          final result = await next();
          log.add('after:$name');
          return result;
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'greet', description: ''),
          handler: (_, _) async => 'hello',
        ),
      );

      mock
        ..enqueueProgress(
          const MontyPending(functionName: 'greet', arguments: []),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await b.execute('greet()').toList();
      expect(log, ['before:greet', 'after:greet']);
    });

    test('interceptor receives function name and args', () async {
      String? capturedName;
      Map<String, Object?>? capturedArgs;

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) {
          capturedName = name;
          capturedArgs = args;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'greet',
            description: '',
            params: [HostParam(name: 'who', type: HostParamType.string)],
          ),
          handler: (args, _) async => 'hello ${args['who']}',
        ),
      );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'greet',
            arguments: [],
            kwargs: {'who': MontyString('world')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await b.execute('greet(who="world")').toList();
      expect(capturedName, 'greet');
      expect(capturedArgs, {'who': 'world'});
    });

    test('interceptor can short-circuit by not calling next', () async {
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,

        interceptor: (name, args, next) async => 'blocked',
      );
      addTearDown(syncBridge.dispose);

      syncBridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_, _) async => fail('should not be called'),
        ),
      );

      syncMock
        ..enqueueProgress(const MontyPending(functionName: 'fn', arguments: []))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await syncBridge.execute('fn()').toList();
      final result = events.whereType<BridgeFunctionCallResult>().first;
      expect(result.result, 'blocked');
    });

    test('interceptor can throw to reject a call', () async {
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,

        interceptor: (name, args, next) => throw StateError('Access denied'),
      );
      addTearDown(syncBridge.dispose);

      syncBridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_, _) async => fail('should not be called'),
        ),
      );

      syncMock
        ..enqueueProgress(const MontyPending(functionName: 'fn', arguments: []))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await syncBridge.execute('fn()').toList();
      final result = events.whereType<BridgeFunctionCallResult>().first;
      expect(result.result, contains('Access denied'));
    });

    test('no interceptor = fast path (handler called directly)', () async {
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

      mock
        ..enqueueProgress(const MontyPending(functionName: 'fn', arguments: []))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn()').toList();
      expect(called, isTrue);
    });

    test('interceptor works on futures path', () async {
      final log = <String>[];

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          log.add('before:$name');
          final result = await next();
          log.add('after:$name');
          return result;
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'async_fn', description: ''),
          handler: (_, _) async => 'result',
        ),
      );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'async_fn',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await b.execute('await async_fn()').toList();
      expect(log, ['before:async_fn', 'after:async_fn']);
    });

    test('isInfra: true bypasses interceptor', () async {
      var interceptorCalled = false;

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          interceptorCalled = true;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_, _) async => 'infra result',
          isInfra: true,
        ),
      );

      mock
        ..enqueueProgress(const MontyPending(functionName: 'fn', arguments: []))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await b.execute('fn()').toList();
      expect(interceptorCalled, isFalse);
    });
  });

  group('MontyOsCall handling', () {
    test('resumes with PermissionError when no handler registered', () async {
      mock
        ..enqueueProgress(
          const MontyOsCall(
            operationName: 'Path.read_text',
            arguments: [MontyString('/etc/passwd')],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('path.read_text()').toList();

      // Should have completed (not deadlocked).
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // Should have called resumeWithError with PermissionError.
      expect(mock.history.resumeErrorMessages, hasLength(1));
      expect(
        mock.history.resumeErrorMessages.first,
        contains('PermissionError'),
      );
      expect(
        mock.history.resumeErrorMessages.first,
        contains('Path.read_text'),
      );

      // Should have emitted OsCall events.
      final starts = events.whereType<BridgeOsCallStart>().toList();
      expect(starts, hasLength(1));
      expect(starts.first.operationName, 'Path.read_text');
      final results = events.whereType<BridgeOsCallResult>().toList();
      expect(results, hasLength(1));
      expect(results.first.result, contains('PermissionError'));
    });

    test('invokes registered handler and resumes with result', () async {
      bridge.registerOs((operation, args, kwargs) async {
        if (operation == 'os.getenv') {
          return 'production';
        }
        return null;
      });

      mock
        ..enqueueProgress(
          const MontyOsCall(
            operationName: 'os.getenv',
            arguments: [MontyString('APP_ENV')],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('os.getenv("APP_ENV")').toList();

      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // Should have called resume with the handler result.
      expect(mock.history.resumeReturnValues, hasLength(1));
      expect(mock.history.resumeReturnValues.first, 'production');

      // Should have emitted OsCall events.
      final starts = events.whereType<BridgeOsCallStart>().toList();
      expect(starts, hasLength(1));
      expect(starts.first.operationName, 'os.getenv');
      final results = events.whereType<BridgeOsCallResult>().toList();
      expect(results, hasLength(1));
      expect(results.first.result, 'production');
    });

    test('handler exception resumes with error', () async {
      bridge.registerOs((operation, args, kwargs) async {
        throw StateError('disk on fire');
      });

      mock
        ..enqueueProgress(
          const MontyOsCall(
            operationName: 'Path.write_text',
            arguments: [MontyString('/tmp/out'), MontyString('data')],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('path.write_text()').toList();

      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // Should have called resumeWithError.
      expect(mock.history.resumeErrorMessages, hasLength(1));
      expect(mock.history.resumeErrorMessages.first, contains('disk on fire'));

      // OsCallResult should contain the error.
      final results = events.whereType<BridgeOsCallResult>().toList();
      expect(results, hasLength(1));
      expect(results.first.result, contains('disk on fire'));
    });

    test('registerOs after dispose throws StateError', () {
      bridge.dispose();
      expect(
        () => bridge.registerOs((op, args, kwargs) async => null),
        throwsStateError,
      );
    });

    test('bridge.dispose() without handler registered does not throw', () {
      // No handler registered — dispose should be a clean no-op.
      bridge.dispose();

      // Calling again (already disposed) should not double-dispose.
      // registerOs should throw since disposed.
      expect(
        () => bridge.registerOs((op, args, kwargs) async => null),
        throwsStateError,
      );
    });
  });

  group('invokeHostFunction', () {
    test('routes through interceptor with correct name and args', () async {
      String? capturedName;
      Map<String, Object?>? capturedArgs;

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) {
          capturedName = name;
          capturedArgs = args;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'greet',
            description: '',
            params: [HostParam(name: 'who', type: HostParamType.string)],
          ),
          handler: (args, _) async => 'hello ${args['who']}',
        ),
      );

      final result = await b.invokeHostFunction('greet', {'who': 'world'});

      expect(result, 'hello world');
      expect(capturedName, 'greet');
      expect(capturedArgs, {'who': 'world'});
    });

    test('unknown function throws ArgumentError', () {
      expect(() => bridge.invokeHostFunction('nope', {}), throwsArgumentError);
    });

    test(
      'setOsHandler(null) clears; restoring via setOsHandler roundtrips',
      () async {
        Future<Object?> handlerA(
          String op,
          List<Object?> args,
          Map<String, Object?>? kwargs,
        ) async => 'A';
        Future<Object?> handlerB(
          String op,
          List<Object?> args,
          Map<String, Object?>? kwargs,
        ) async => 'B';

        final b = MontyBridge(platform: mock) as PlatformBridge;
        addTearDown(b.dispose);

        OsCallHandler? captured;
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
      'HostContext.os reflects currently-registered OsCallHandler',
      () async {
        OsCallHandler? capturedOs;
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
        Future<Object?> handler(
          String op,
          List<Object?> args,
          Map<String, Object?>? kwargs,
        ) async => 'ok';
        bridge.registerOs(handler);

        await bridge.invokeHostFunction('peek_os', const {});
        expect(capturedOs, same(handler));
      },
    );

    test('isInfra: true bypasses interceptor on direct invoke', () async {
      var interceptorCalled = false;

      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          interceptorCalled = true;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_, _) async => 'result',
          isInfra: true,
        ),
      );

      final result = await b.invokeHostFunction('fn', {});

      expect(result, 'result');
      expect(interceptorCalled, isFalse);
    });

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

    test('with onEvent — interceptor still wraps the call', () async {
      var interceptorRan = false;
      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          interceptorRan = true;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'streamer', description: ''),
          handler: (_, ctx) async {
            ctx.emitText('mid');
            return 'ok';
          },
        ),
      );

      final received = <BridgeEvent>[];
      final result = await b.invokeHostFunction(
        'streamer',
        const {},
        onEvent: received.add,
      );

      expect(result, 'ok');
      expect(interceptorRan, isTrue);
      expect(received, hasLength(1));
      expect((received.single as BridgeFunctionEmit).text, 'mid');
    });

    test('with onEvent — infra bypasses interceptor; events deliver', () async {
      var interceptorRan = false;
      final b = MontyBridge(
        platform: mock,
        interceptor: (name, args, next) async {
          interceptorRan = true;
          return next();
        },
      );
      addTearDown(b.dispose);

      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'infra_fn', description: ''),
          isInfra: true,
          handler: (_, ctx) async {
            ctx.emitText('infra');
            return null;
          },
        ),
      );

      final received = <BridgeEvent>[];
      await b.invokeHostFunction(
        'infra_fn',
        const {},
        onEvent: received.add,
      );

      expect(interceptorRan, isFalse);
      expect(received, hasLength(1));
      expect((received.single as BridgeFunctionEmit).text, 'infra');
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
      final throwingMock = _ThrowingOnResumePlatform(
        throwOnResume: const MontyPanicError('WASM trap'),
      );
      final b = MontyBridge(
        platform: throwingMock,

        logger: const NullBridgeLogger(),
      );
      addTearDown(b.dispose);

      // Register a noop function so the bridge dispatches it and calls
      // _platform.resume(), which throws MontyPanicError (a MontyError).
      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'noop', description: ''),
          handler: (_, _) async => null,
        ),
      );
      throwingMock.enqueueProgress(
        const MontyPending(functionName: 'noop', arguments: []),
      );

      final events = await b.execute('noop()').toList();
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.message, contains('WASM trap'));
    });

    test(
      'generic Object thrown during execution emits BridgeRunError',
      () async {
        final throwingMock = _ThrowingOnResumePlatform(
          throwOnResume: 'unexpected string error',
        );
        final b = MontyBridge(
          platform: throwingMock,

          logger: const NullBridgeLogger(),
        );
        addTearDown(b.dispose);

        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'noop', description: ''),
            handler: (_, _) async => null,
          ),
        );
        throwingMock.enqueueProgress(
          const MontyPending(functionName: 'noop', arguments: []),
        );

        final events = await b.execute('noop()').toList();
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('unexpected string error'));
      },
    );

    test(
      'MontyError mid-execution emits BridgeRunError (no printOutput)',
      () async {
        // Without the print preamble, printOutput for infrastructure errors
        // is null — Monty cannot surface print output when the interpreter
        // itself panics.
        final throwingMock = _PrintThenThrowPlatform();
        final b = MontyBridge(
          platform: throwingMock,

          logger: const NullBridgeLogger(),
        );
        addTearDown(b.dispose);

        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'noop', description: ''),
            handler: (_, _) async => null,
          ),
        );
        throwingMock
          ..enqueueProgress(
            const MontyPending(functionName: 'noop', arguments: []),
          )
          ..throwAfterResumes = 0;

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

    test('execute while already executing throws StateError', () async {
      // Start one execution.
      mock.enqueueProgress(
        const MontyComplete(
          result: MontyResult(value: MontyNone(), usage: _usage),
        ),
      );
      final stream = bridge.execute('1');
      // Try starting another before the first completes.
      expect(() => bridge.execute('2'), throwsStateError);
      // Drain the first stream so cleanup happens.
      await stream.toList();
    });
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
    test('unknown function in pending resumes with error', () async {
      mock
        ..enqueueProgress(
          const MontyPending(functionName: 'not_registered', arguments: []),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('not_registered()').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(mock.history.resumeErrorMessages, hasLength(1));
      expect(
        mock.history.resumeErrorMessages.first,
        contains('Unknown function: not_registered'),
      );
    });
  });

  group('argument validation error in _dispatchToolCall', () {
    test('FormatException from mapAndValidate resumes with error', () async {
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,

        logger: const NullBridgeLogger(),
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
      syncMock
        ..enqueueProgress(
          const MontyPending(functionName: 'need_param', arguments: []),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await syncBridge.execute('need_param()').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(syncMock.history.resumeErrorMessages, hasLength(1));
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

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'need_param',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('need_param()').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(mock.history.resumeErrorMessages, hasLength(1));
    });
  });

  group('ResolveFutures without futures-capable platform', () {
    test('resumes with null when not futures-capable and no pending', () async {
      // Non-futures-capable platform — ResolveFutures just resumes with null.
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,

        logger: const NullBridgeLogger(),
      );
      addTearDown(syncBridge.dispose);

      syncMock
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await syncBridge.execute('code').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
    });
  });

  // Regression: resume() failure must not cause StateError (#274).
  //
  // Before the fix, _dispatchToolCall wrapped both the handler invocation
  // AND platform.resume() in the same try/catch. If resume() threw
  // (marking the platform idle), the catch called resumeWithError() on
  // the idle platform → StateError.
  group('resume() failure recovery (#274)', () {
    test(
      'handler succeeds but resume() throws — emits BridgeRunError',
      () async {
        // Platform throws when resume() is called with 'hello'.
        final failMock = _ResumeFailsPlatform()..failOnValue = 'hello';
        final failBridge = MontyBridge(platform: failMock)
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'greet',
                description: 'Returns hello',
              ),
              handler: (_, _) async => 'hello',
            ),
          );

        // start → Pending(greet) → handler returns 'hello' →
        // resume('hello') throws because failOnValue matches.
        failMock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'greet',
              arguments: [],
              callId: 1,
            ),
          )
          // Enqueued for resume but never consumed — throw happens first.
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

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
        expect(errors.first.message, contains('resume failed'));

        failBridge.dispose();
      },
    );

    test(
      'multiple tool calls — resume failure on 3rd does not StateError',
      () async {
        // Fail when resuming with value '3' (the 3rd call).
        final failMock = _ResumeFailsPlatform()..failOnValue = '3';
        final failBridge = MontyBridge(platform: failMock)
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

        // start → Pending(count,n=1) → resume(1) OK →
        // Pending(count,n=2) → resume(2) OK →
        // Pending(count,n=3) → resume(3) THROWS
        failMock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'count',
              arguments: [MontyInt(1)],
              kwargs: {'n': MontyInt(1)},
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'count',
              arguments: [MontyInt(2)],
              kwargs: {'n': MontyInt(2)},
              callId: 2,
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'count',
              arguments: [MontyInt(3)],
              kwargs: {'n': MontyInt(3)},
              callId: 3,
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final events = await failBridge.execute('code').toList();

        // First two succeed, 3rd triggers error.
        final errors = events.whereType<BridgeRunError>().toList();
        expect(
          errors,
          hasLength(1),
          reason:
              'Expected BridgeRunError, got: '
              '${events.map((e) => e.runtimeType).toList()}',
        );
        expect(errors.first.message, contains('resume failed'));

        // First two tool calls should have result events.
        final results = events.whereType<BridgeFunctionCallResult>().toList();
        expect(results.length, greaterThanOrEqualTo(2));

        failBridge.dispose();
      },
    );
  });
}

/// A mock platform that throws from [resume] after enqueued progresses
/// are consumed via [start].
class _ThrowingOnResumePlatform extends MockMontyPlatform {
  _ThrowingOnResumePlatform({required this.throwOnResume});

  final Object throwOnResume;

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    // ignore: only_throw_errors – test intentionally throws non-Exception objects.
    throw throwOnResume;
  }
}

/// A mock platform that throws [MontyPanicError] after N resume calls.
class _PrintThenThrowPlatform extends MockMontyPlatform {
  int throwAfterResumes = 0;
  int _resumeCount = 0;

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    _resumeCount++;
    if (_resumeCount > throwAfterResumes) {
      throw const MontyPanicError('panic after print');
    }

    return super.resume(returnValue);
  }
}

/// A mock platform that throws on resume() when the return value matches.
class _ResumeFailsPlatform extends MockMontyPlatform {
  String? failOnValue;

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    if (failOnValue != null && returnValue?.toString() == failOnValue) {
      throw const MontyPanicError('resume failed on value');
    }

    return super.resume(returnValue);
  }
}
