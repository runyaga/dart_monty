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
  // 1. MontySession sends __restore_state__() → platform returns pending
  mock.enqueueProgress(
    const MontyPending(functionName: '__restore_state__', arguments: []),
  );
  // 2. After restore resumes, code runs, then __persist_state__(dict)
  mock.enqueueProgress(
    MontyPending(
      functionName: '__persist_state__',
      arguments: [persistedState],
    ),
  );
  // 3. After persist resumes, execution completes
  mock.enqueueProgress(MontyComplete(result: result));
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
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;
