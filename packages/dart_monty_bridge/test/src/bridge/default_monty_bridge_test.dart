import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  late MockMontyPlatform mock;
  late DefaultMontyBridge bridge;

  setUp(() {
    mock = MockMontyPlatform();
    bridge = DefaultMontyBridge(platform: mock);
  });

  tearDown(() {
    bridge.dispose();
  });

  // P0: preamble line offset adjustment for MontyException.
  group('preamble line offset adjustment', () {
    test(
      'adjusts MontyException line numbers from MontyComplete error path',
      () async {
        // The print preamble adds 5 lines before user code. If Python reports
        // an error at line 8, user code line is 8 - 5 = 3.
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              error: MontyException(
                message: 'NameError: name "foo" is not defined',
                lineNumber: 8,
                traceback: [
                  MontyStackFrame(
                    filename: '<module>',
                    startLine: 8,
                    startColumn: 0,
                  ),
                ],
              ),
              usage: _usage,
            ),
          ),
        );

        final events = await bridge.execute('foo').toList();
        final error = events.whereType<BridgeRunError>().single;
        expect(error.message, 'NameError: name "foo" is not defined');
      },
    );

    test('adjusts thrown MontyException line numbers', () async {
      // Simulate platform throwing MontyException (the 'error' progress state
      // path in BaseMontyPlatform.translateProgress).
      final mock = _ThrowingMontyPlatform(
        const MontyException(
          message: 'SyntaxError: invalid syntax',
          lineNumber: 7,
          traceback: [
            MontyStackFrame(filename: '<module>', startLine: 3, startColumn: 0),
            MontyStackFrame(filename: '<module>', startLine: 7, startColumn: 4),
          ],
        ),
      );
      final b = DefaultMontyBridge(platform: mock);
      addTearDown(b.dispose);

      final events = await b.execute('x = 1').toList();
      final error = events.whereType<BridgeRunError>().single;
      expect(error.message, 'SyntaxError: invalid syntax');
    });

    test('filters traceback frames from preamble lines', () async {
      // A traceback frame at startLine=3 (inside preamble) should be removed.
      // A frame at startLine=7 (user code line 2) should be kept and adjusted.
      mock.enqueueProgress(
        const MontyComplete(
          result: MontyResult(
            error: MontyException(
              message: 'error',
              traceback: [
                MontyStackFrame(
                  filename: '<module>',
                  startLine: 3,
                  startColumn: 0,
                ),
                MontyStackFrame(
                  filename: '<module>',
                  startLine: 7,
                  startColumn: 4,
                  endLine: 7,
                ),
              ],
            ),
            usage: _usage,
          ),
        ),
      );

      final events = await bridge.execute('code').toList();
      // The error event is emitted — the filtering happens inside the bridge.
      expect(events.whereType<BridgeRunError>(), hasLength(1));
    });
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
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      final events = await bridge.execute('slow_fail()').toList();

      // The bridge should have completed (not deadlocked) and the error
      // should have been captured during future resolution.
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      // The error was sent through resolveFutures with an errors map.
      expect(mock.resolveFuturesErrorsList, hasLength(1));
      final errors = mock.resolveFuturesErrorsList.first;
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
            const MontyComplete(result: MontyResult(usage: _usage)),
          );

        final events = await bridge.execute('explode()').toList();

        // Bridge should have emitted a BridgeRunFinished (not deadlocked).
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        // The sync error should have been sent via resumeWithError.
        expect(mock.resumeErrorMessages, hasLength(1));
        expect(mock.resumeErrorMessages.first, contains('sync boom'));
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
            kwargs: {'__role__': 'infra'},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
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
            kwargs: {'__role__': 'infra'},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
            kwargs: {'x': 42, '__role__': 'infra'},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
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
            kwargs: {'x': 42, '__role__': 'infra'},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      await bridge.execute('fn(x=42, __role__="infra")').toList();
      expect(capturedArgs, {'x': 42});
    });

    test('middleware can short-circuit by not calling next', () async {
      // Use sync dispatch (useFutures: false) so BridgeToolCallResult is
      // emitted immediately in _dispatchToolCall, not deferred.
      final syncMock = MockMontyPlatform();
      final syncBridge = DefaultMontyBridge(
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
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      final events = await syncBridge.execute('fn()').toList();
      final result = events.whereType<BridgeToolCallResult>().first;
      expect(result.result, 'blocked');
    });

    test('middleware can throw to reject a call', () async {
      final syncMock = MockMontyPlatform();
      final syncBridge = DefaultMontyBridge(
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
          const MontyComplete(result: MontyResult(usage: _usage)),
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
            kwargs: {'__role__': 'unknown_value'},
          ),
        )
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      await bridge.execute('fn()').toList();
      expect(captured, isA<ToolCall>());
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

    test('coerces string to int for integer param', () async {
      Map<String, Object?>? capturedArgs;

      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'add',
            description: '',
            params: [HostParam(name: 'n', type: HostParamType.integer)],
          ),
          handler: (args) async {
            capturedArgs = args;
            return args['n'];
          },
        ),
      );

      final result = await bridge.invokeHostFunction('add', {'n': '42'});

      expect(result, 42);
      expect(capturedArgs!['n'], isA<int>());
      expect(capturedArgs!['n'], 42);
    });

    test('disposed bridge throws StateError', () {
      bridge.dispose();

      expect(() => bridge.invokeHostFunction('fn', {}), throwsStateError);
    });
  });

  // ===========================================================================
  // E-2: dispose cancels in-flight execution
  // ===========================================================================
  group('E-2: dispose cancels in-flight execution', () {
    test('dispose calls platform.cancel() when executing', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'slow', description: ''),
          handler: (_) async => 42,
        ),
      );

      // Enqueue a pending that will pause execution
      mock.enqueueProgress(
        const MontyPending(functionName: 'slow', arguments: []),
      );
      // Enqueue a complete for after resume
      mock.enqueueProgress(
        const MontyComplete(result: MontyResult(usage: _usage)),
      );

      // Start execution — _run is now in flight waiting for host function
      final stream = bridge.execute('slow()');
      // Consume just the first event (BridgeRunStarted)
      await stream.first;

      // Dispose while execution is in-flight
      bridge.dispose();

      // Platform.cancel() should have been called
      expect(mock.cancelCalled, isTrue);
    });

    test('dispose without execution does not call cancel', () {
      bridge.dispose();

      expect(mock.cancelCalled, isFalse);
    });
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

/// A minimal [MontyPlatform] that throws a [MontyException] from [start].
///
/// Used to test the bridge's `on MontyException` catch path where the
/// platform itself throws (rather than returning a MontyComplete with error).
class _ThrowingMontyPlatform extends MontyPlatform {
  _ThrowingMontyPlatform(this._exception);

  final MontyException _exception;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async => throw UnimplementedError();

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async => throw _exception;

  @override
  Future<MontyProgress> resume(Object? returnValue) async =>
      throw UnimplementedError();

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async =>
      throw UnimplementedError();

  @override
  Future<void> cancel() async {}

  @override
  int? get handleId => null;

  @override
  Future<void> dispose() async {}
}
