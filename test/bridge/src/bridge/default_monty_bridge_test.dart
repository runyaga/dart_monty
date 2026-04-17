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
          handler: (_) async {
            throw StateError('async kaboom');
          },
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
            handler: (_) => throw StateError('sync boom'),
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

  group('BridgeMiddleware', () {
    test('use() registers middleware called on tool dispatch', () async {
      final log = <String>[];

      bridge
        ..use(_LoggingMiddleware('mw1', log))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'greet', description: ''),
            handler: (_) async => 'hello',
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

      await bridge.execute('greet()').toList();
      expect(log, ['mw1:before:greet', 'mw1:after:greet']);
    });

    test('onion chain order: first registered = outermost', () async {
      final log = <String>[];

      bridge
        ..use(_LoggingMiddleware('outer', log))
        ..use(_LoggingMiddleware('inner', log))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async {
              log.add('handler');
              return null;
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
      expect(log, [
        'outer:before:fn',
        'inner:before:fn',
        'handler',
        'inner:after:fn',
        'outer:after:fn',
      ]);
    });

    test('middleware receives ToolCall role by default', () async {
      CallRole? captured;

      bridge
        ..use(_RoleCapturingMiddleware((role) => captured = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
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
      expect(captured, isA<ToolCall>());
    });

    test('__role__=infra kwarg sets InfraCall role (no host role)', () async {
      CallRole? captured;

      bridge
        ..use(_RoleCapturingMiddleware((role) => captured = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
          ),
        );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'__role__': MontyString('infra')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn(__role__="infra")').toList();
      expect(captured, isA<InfraCall>());
    });

    test('host-declared role overrides __role__ kwarg', () async {
      CallRole? captured;

      bridge
        ..use(_RoleCapturingMiddleware((role) => captured = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
            role: const ToolCall(),
          ),
        );

      // Python sends __role__=infra but host declares ToolCall.
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'__role__': MontyString('infra')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn(__role__="infra")').toList();
      // Host role wins — Python cannot escalate to InfraCall.
      expect(captured, isA<ToolCall>());
    });

    test('host-declared InfraCall role used even without kwarg', () async {
      CallRole? captured;

      bridge
        ..use(_RoleCapturingMiddleware((role) => captured = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
            role: const InfraCall(),
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
      expect(captured, isA<InfraCall>());
    });

    test('__role__ kwarg stripped even when host role overrides', () async {
      Map<String, Object?>? capturedArgs;

      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fn',
            description: '',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          handler: (args) async {
            capturedArgs = args;
            return null;
          },
          role: const ToolCall(),
        ),
      );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'x': MontyInt(42), '__role__': MontyString('infra')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn(x=42, __role__="infra")').toList();
      expect(capturedArgs, {'x': 42});
    });

    test('__role__ kwarg is stripped before mapAndValidate', () async {
      Map<String, Object?>? capturedArgs;

      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fn',
            description: '',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          handler: (args) async {
            capturedArgs = args;
            return null;
          },
        ),
      );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'x': MontyInt(42), '__role__': MontyString('infra')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn(x=42, __role__="infra")').toList();
      expect(capturedArgs, {'x': 42});
    });

    test('middleware can short-circuit by not calling next', () async {
      // Use sync dispatch (useFutures: false) so BridgeToolCallResult is
      // emitted immediately in _dispatchToolCall, not deferred.
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,
        useFutures: false,
      );
      addTearDown(syncBridge.dispose);

      syncBridge
        ..use(_BlockingMiddleware('blocked'))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => fail('should not be called'),
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
      final result = events.whereType<BridgeToolCallResult>().first;
      expect(result.result, 'blocked');
    });

    test('middleware can throw to reject a call', () async {
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,
        useFutures: false,
      );
      addTearDown(syncBridge.dispose);

      syncBridge
        ..use(_ThrowingMiddleware())
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => fail('should not be called'),
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
      final result = events.whereType<BridgeToolCallResult>().first;
      expect(result.result, contains('Access denied'));
    });

    test('no middleware = fast path (handler called directly)', () async {
      var called = false;
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'fn', description: ''),
          handler: (_) async {
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

    test('use() after dispose throws StateError', () {
      bridge.dispose();
      expect(() => bridge.use(_LoggingMiddleware('x', [])), throwsStateError);
    });

    test('middleware works on futures path', () async {
      final log = <String>[];

      bridge
        ..use(_LoggingMiddleware('mw', log))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'async_fn', description: ''),
            handler: (_) async => 'result',
          ),
        );

      // Futures path: Pending -> resumeAsFuture -> ResolveFutures -> Complete
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

      await bridge.execute('await async_fn()').toList();
      expect(log, ['mw:before:async_fn', 'mw:after:async_fn']);
    });

    test('unknown __role__ value defaults to ToolCall', () async {
      CallRole? captured;

      bridge
        ..use(_RoleCapturingMiddleware((role) => captured = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
          ),
        );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'__role__': MontyString('unknown_value')},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('fn()').toList();
      expect(captured, isA<ToolCall>());
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
      bridge.registerOs(
        _TestOsProvider((call) async {
          if (call.operationName == 'os.getenv') {
            return 'production';
          }
          return null;
        }),
      );

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
      bridge.registerOs(
        _TestOsProvider((call) async {
          throw StateError('disk on fire');
        }),
      );

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
        () => bridge.registerOs(_TestOsProvider((_) async => null)),
        throwsStateError,
      );
    });

    test('bridge.dispose() disposes registered OsProvider', () {
      final handler = _DisposableOsProvider();
      bridge
        ..registerOs(handler)
        ..dispose();

      expect(handler.disposed, isTrue);
      expect(handler.disposeCount, 1);
    });

    test('bridge.dispose() without handler registered does not throw', () {
      // No handler registered — dispose should be a clean no-op.
      bridge.dispose();

      // Calling again (already disposed) should not double-dispose.
      // registerOs should throw since disposed.
      expect(
        () => bridge.registerOs(_DisposableOsProvider()),
        throwsStateError,
      );
    });
  });

  group('invokeHostFunction', () {
    test(
      'routes through middleware with correct name, args, and role',
      () async {
        String? capturedName;
        Map<String, Object?>? capturedArgs;
        CallRole? capturedRole;

        bridge
          ..use(
            _CapturingMiddleware(
              onCall: (name, args, role) {
                capturedName = name;
                capturedArgs = args;
                capturedRole = role;
              },
            ),
          )
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'greet',
                description: '',
                params: [HostParam(name: 'who', type: HostParamType.string)],
              ),
              handler: (args) async => 'hello ${args['who']}',
            ),
          );

        final result = await bridge.invokeHostFunction('greet', {
          'who': 'world',
        });

        expect(result, 'hello world');
        expect(capturedName, 'greet');
        expect(capturedArgs, {'who': 'world'});
        expect(capturedRole, isA<ToolCall>());
      },
    );

    test('unknown function throws ArgumentError', () {
      expect(() => bridge.invokeHostFunction('nope', {}), throwsArgumentError);
    });

    test('propagates InfraCall role to middleware', () async {
      CallRole? capturedRole;

      bridge
        ..use(_RoleCapturingMiddleware((role) => capturedRole = role))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'fn', description: ''),
            handler: (_) async => null,
          ),
        );

      await bridge.invokeHostFunction('fn', {}, role: const InfraCall());

      expect(capturedRole, isA<InfraCall>());
    });

    test('validates arguments via mapAndValidate', () {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'need_name',
            description: '',
            params: [HostParam(name: 'name', type: HostParamType.string)],
          ),
          handler: (_) async => null,
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
          handler: (args) async => args['n'],
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

  group('error handling in _run', () {
    test('MontyError thrown during execution emits BridgeRunError', () async {
      final throwingMock = _ThrowingOnResumePlatform(
        throwOnResume: const MontyPanicError('WASM trap'),
      );
      final b = MontyBridge(
        platform: throwingMock,
        useFutures: false,
        logger: const NullBridgeLogger(),
      );
      addTearDown(b.dispose);

      // Register a noop function so the bridge dispatches it and calls
      // _platform.resume(), which throws MontyPanicError (a MontyError).
      b.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'noop', description: ''),
          handler: (_) async => null,
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
          useFutures: false,
          logger: const NullBridgeLogger(),
        );
        addTearDown(b.dispose);

        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'noop', description: ''),
            handler: (_) async => null,
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
          useFutures: false,
          logger: const NullBridgeLogger(),
        );
        addTearDown(b.dispose);

        b.register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'noop', description: ''),
            handler: (_) async => null,
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
            handler: (_) async => null,
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
          handler: (_) async => null,
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
        useFutures: false,
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
          handler: (_) async => null,
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
          handler: (_) async => null,
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
      // MontyBridge with useFutures: false — ResolveFutures just resumes
      // with null.
      final syncMock = MockMontyPlatform();
      final syncBridge = MontyBridge(
        platform: syncMock,
        useFutures: false,
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
        final failBridge = MontyBridge(platform: failMock, useFutures: false)
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'greet',
                description: 'Returns hello',
              ),
              handler: (_) async => 'hello',
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
        final failBridge = MontyBridge(platform: failMock, useFutures: false)
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'count',
                description: 'Returns incrementing number',
                params: [
                  HostParam(name: 'n', type: HostParamType.integer),
                ],
              ),
              handler: (args) async => args['n'],
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
        final results = events.whereType<BridgeToolCallResult>().toList();
        expect(results.length, greaterThanOrEqualTo(2));

        failBridge.dispose();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test middleware implementations
// ---------------------------------------------------------------------------

class _LoggingMiddleware extends BridgeMiddleware {
  _LoggingMiddleware(this.tag, this.log);

  final String tag;
  final List<String> log;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    log.add('$tag:before:$name');
    final result = await next(name, args);
    log.add('$tag:after:$name');
    return result;
  }
}

class _RoleCapturingMiddleware extends BridgeMiddleware {
  _RoleCapturingMiddleware(this.onRole);

  final void Function(CallRole) onRole;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) {
    onRole(role);
    return next(name, args);
  }
}

class _BlockingMiddleware extends BridgeMiddleware {
  _BlockingMiddleware(this.returnValue);

  final Object? returnValue;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async => returnValue;
}

class _ThrowingMiddleware extends BridgeMiddleware {
  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) => throw StateError('Access denied');
}

class _CapturingMiddleware extends BridgeMiddleware {
  _CapturingMiddleware({required this.onCall});

  final void Function(String name, Map<String, Object?> args, CallRole role)
  onCall;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) {
    onCall(name, args, role);
    return next(name, args);
  }
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

class _TestOsProvider extends OsProvider {
  _TestOsProvider(this._fn) : super.base();
  final Future<Object?> Function(MontyOsCall) _fn;

  @override
  Future<Object?> resolve(MontyOsCall call) => _fn(call);
}

class _DisposableOsProvider extends OsProvider {
  _DisposableOsProvider() : super.base();
  bool disposed = false;
  int disposeCount = 0;

  @override
  Future<Object?> resolve(MontyOsCall call) => Future.value();

  @override
  Future<void> dispose() async {
    disposed = true;
    disposeCount++;
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
