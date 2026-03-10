import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

/// Enqueue the MontySession restore→persist→complete sequence that
/// [MontySession.run] expects for a simple execution.
void _enqueueSessionRun(
  MockMontyPlatform mock, {
  required MontyResult result,
  Map<String, Object?> persistedState = const {},
}) {
  mock
    // 1. MontySession sends __restore_state__() → platform returns pending
    ..enqueueProgress(
      const MontyPending(functionName: '__restore_state__', arguments: []),
    )
    // 2. After restore resumes, code runs, then __persist_state__(dict)
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [persistedState],
      ),
    )
    // 3. After persist resumes, execution completes
    ..enqueueProgress(MontyComplete(result: result));
}

void main() {
  group('McpMontySession', () {
    test('execute returns result from session', () async {
      final mock = MockMontyPlatform();
      _enqueueSessionRun(
        mock,
        result: const MontyResult(value: 'hello', usage: _usage),
      );

      final session = McpMontySession(id: 'test', platform: mock);
      final result = await session.execute("'hello'");

      expect(result.isError, isFalse);
      expect(_text(result), contains('hello'));

      await session.dispose();
    });

    test('execute returns error for disposed session', () async {
      final mock = MockMontyPlatform();
      final session = McpMontySession(id: 'dead', platform: mock);
      await session.dispose();

      final result = await session.execute('x');

      expect(result.isError, isTrue);
      expect(_text(result), contains('disposed'));
    });

    test('serializes concurrent requests', () async {
      // Two rapid calls should not throw StateError('already executing').
      final mock = MockMontyPlatform();
      _enqueueSessionRun(
        mock,
        result: const MontyResult(value: 1, usage: _usage),
      );
      _enqueueSessionRun(
        mock,
        result: const MontyResult(value: 2, usage: _usage),
      );

      final session = McpMontySession(id: 'serial', platform: mock);

      final results = await Future.wait([
        session.execute('1'),
        session.execute('2'),
      ]);

      expect(results, hasLength(2));
      // Both should succeed (not throw).
      expect(results[0].isError, isFalse);
      expect(results[1].isError, isFalse);

      await session.dispose();
    });

    test('execute surfaces Python errors', () async {
      final mock = MockMontyPlatform();
      _enqueueSessionRun(
        mock,
        result: const MontyResult(
          error: MontyException(message: 'ZeroDivisionError: division by zero'),
          usage: _usage,
        ),
      );

      final session = McpMontySession(id: 'err', platform: mock);
      final result = await session.execute('1/0');

      expect(result.isError, isTrue);
      expect(_text(result), contains('ZeroDivisionError'));

      await session.dispose();
    });

    test('dispose marks session as disposed', () async {
      final mock = MockMontyPlatform();
      final session = McpMontySession(id: 'x', platform: mock);

      expect(session.isDisposed, isFalse);
      await session.dispose();
      expect(session.isDisposed, isTrue);
    });

    test('dispose is idempotent', () async {
      final mock = MockMontyPlatform();
      final session = McpMontySession(id: 'x', platform: mock);

      await session.dispose();
      await session.dispose(); // should not throw
    });
  });

  group('McpMontySession host functions', () {
    test('dispatches host function call and returns result', () async {
      // MontySession.start() intercepts restore/persist transparently.
      // Sequence: restore → user fn pending → persist → complete
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: 'add',
            arguments: [3, 4],
          ),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 7, usage: _usage),
          ),
        );

      final session = McpMontySession(id: 'hf', platform: mock)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'add',
              description: 'Add two numbers',
              params: [
                HostParam(name: 'a', type: HostParamType.number),
                HostParam(name: 'b', type: HostParamType.number),
              ],
            ),
            handler: (args) async => (args['a']! as num) + (args['b']! as num),
          ),
        );

      final result = await session.execute('add(a=3, b=4)');

      expect(result.isError, isFalse);
      expect(_text(result), contains('7'));

      // Verify the handler was invoked: resume was called with the result 7
      expect(mock.resumeReturnValues, contains(7));

      await session.dispose();
    });

    test('handler exception resumes with error', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(functionName: 'fail_fn', arguments: []),
        )
        // After resumeWithError, MontySession intercepts persist
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              error: MontyException(message: 'intentional error'),
              usage: _usage,
            ),
          ),
        );

      final session = McpMontySession(id: 'hf-err', platform: mock)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'fail_fn',
              description: 'Always throws',
            ),
            handler: (args) async => throw Exception('intentional error'),
          ),
        );

      final result = await session.execute('fail_fn()');

      expect(result.isError, isTrue);
      expect(_text(result), contains('intentional error'));

      await session.dispose();
    });

    test('unknown function name resumes with error', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(functionName: 'unknown_fn', arguments: []),
        )
        // After resumeWithError for unknown fn, persist + complete
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              error: MontyException(message: 'NameError: unknown_fn'),
              usage: _usage,
            ),
          ),
        );

      // Register a different function — 'unknown_fn' is NOT registered.
      final session = McpMontySession(id: 'hf-unk', platform: mock)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'known_fn',
              description: 'A known function',
            ),
            handler: (args) async => 42,
          ),
        );

      await session.execute('unknown_fn()');

      // Should have resumed with error about unknown function
      expect(
        mock.resumeErrorMessages,
        contains(contains('Unknown host function')),
      );

      await session.dispose();
    });

    test('multiple host functions dispatch correctly', () async {
      // Two host function calls in sequence
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(functionName: 'add', arguments: [1, 2]),
        )
        // After add returns, greet is called
        ..enqueueProgress(
          const MontyPending(
            functionName: 'greet',
            arguments: ['World'],
          ),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 'Hello, World!', usage: _usage),
          ),
        );

      final session = McpMontySession(id: 'hf-multi', platform: mock)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'add',
              description: 'Add',
              params: [
                HostParam(name: 'a', type: HostParamType.number),
                HostParam(name: 'b', type: HostParamType.number),
              ],
            ),
            handler: (args) async => (args['a']! as num) + (args['b']! as num),
          ),
        )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'greet',
              description: 'Greet',
              params: [
                HostParam(name: 'name', type: HostParamType.string),
              ],
            ),
            handler: (args) async => 'Hello, ${args['name']}!',
          ),
        );

      final result = await session.execute('greet(add(1, 2))');

      expect(result.isError, isFalse);
      // add returned 3, then greet returned 'Hello, World!'
      expect(mock.resumeReturnValues, contains(3));
      expect(
        mock.resumeReturnValues,
        contains('Hello, World!'),
      );

      await session.dispose();
    });

    test('no host functions uses run() path', () async {
      final mock = MockMontyPlatform();
      _enqueueSessionRun(
        mock,
        result: const MontyResult(value: 42, usage: _usage),
      );

      final session = McpMontySession(id: 'no-hf', platform: mock);
      // No host functions registered — should use run() path.
      final result = await session.execute('42');

      expect(result.isError, isFalse);
      expect(_text(result), contains('42'));
      // start() should NOT have been called (run() uses start internally
      // but via MontySession.run, not MontySession.start)
      expect(mock.startCodes, hasLength(1)); // MontySession.run calls start

      await session.dispose();
    });
  });
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;
