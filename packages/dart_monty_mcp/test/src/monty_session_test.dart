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

void main() {
  group('McpMontySession', () {
    test('execute returns result from bridge', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 'hello', usage: _usage),
          ),
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
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 1, usage: _usage),
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 2, usage: _usage),
          ),
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
