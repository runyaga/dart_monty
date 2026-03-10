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

/// Creates a [MontyMcpServer] whose platform factory returns mocks
/// that complete with [value] (stateless execution via bridge).
MontyMcpServer _serverWithResult(Object? value) {
  return MontyMcpServer(
    platformFactory: () => MockMontyPlatform()
      ..enqueueProgress(
        MontyComplete(result: MontyResult(value: value, usage: _usage)),
      ),
  );
}

/// Creates a mock platform with the restore→persist→complete sequence
/// that [MontySession.run] (used by [McpMontySession]) expects.
MockMontyPlatform _mockForSessionExec({
  required MontyResult result,
  Map<String, Object?> persistedState = const {},
}) {
  return MockMontyPlatform()
    ..enqueueProgress(
      const MontyPending(functionName: '__restore_state__', arguments: []),
    )
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [persistedState],
      ),
    )
    ..enqueueProgress(MontyComplete(result: result));
}

void main() {
  group('MontyMcpServer tool routing', () {
    test('monty_run routes to stateless execution', () async {
      final server = _serverWithResult(42);

      final result = await server.sessionManager.executeStateless('2 + 2');

      expect(result.isError, isFalse);
      expect(_text(result), contains('42'));

      await server.dispose();
    });

    test('session create → exec → destroy lifecycle', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForSessionExec(
          result: const MontyResult(value: 'hello', usage: _usage),
        ),
      );
      final manager = server.sessionManager;

      // Create
      final id = manager.createSession(id: 'test-session');
      expect(id, 'test-session');
      expect(manager.sessionCount, 1);

      // Exec
      final session = manager.getSession('test-session')!;
      final result = await session.execute("'hello'");
      expect(result.isError, isFalse);
      expect(_text(result), contains('hello'));

      // Destroy
      final destroyed = await manager.destroySession('test-session');
      expect(destroyed, isTrue);
      expect(manager.sessionCount, 0);

      await server.dispose();
    });

    test('session exec on unknown session returns error', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      final session = server.sessionManager.getSession('nonexistent');
      expect(session, isNull);

      await server.dispose();
    });

    test('session create with duplicate ID returns null', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      final manager = server.sessionManager;

      final first = manager.createSession(id: 'dup');
      final duplicate = manager.createSession(id: 'dup');
      expect(first, 'dup');
      expect(duplicate, isNull);
      expect(manager.sessionCount, 1);

      await server.dispose();
    });

    test('session list returns active session IDs', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      server.sessionManager
        ..createSession(id: 'alpha')
        ..createSession(id: 'beta');

      expect(
        server.sessionManager.sessionIds,
        containsAll(['alpha', 'beta']),
      );

      await server.dispose();
    });

    test('dispose cleans up all sessions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      server.sessionManager
        ..createSession(id: 'a')
        ..createSession(id: 'b');

      await server.dispose();

      expect(server.sessionManager.sessionCount, 0);
    });

    test('destroy nonexistent session returns false', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      final destroyed =
          await server.sessionManager.destroySession('ghost');
      expect(destroyed, isFalse);

      await server.dispose();
    });
  });
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;
