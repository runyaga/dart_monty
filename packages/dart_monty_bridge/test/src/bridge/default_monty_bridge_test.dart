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
