import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('MontySessionManager', () {
    late MontySessionManager manager;

    setUp(() {
      manager = MontySessionManager(
        platformFactory: MockMontyPlatform.new,
      );
    });

    tearDown(() async {
      await manager.disposeAll();
    });

    test('createSession generates sequential IDs', () {
      final id1 = manager.createSession();
      final id2 = manager.createSession();

      expect(id1, 'session_0');
      expect(id2, 'session_1');
      expect(manager.sessionCount, 2);
    });

    test('createSession with custom ID', () {
      final id = manager.createSession(id: 'my-session');

      expect(id, 'my-session');
      expect(manager.getSession('my-session'), isNotNull);
    });

    test('createSession returns null for duplicate ID', () {
      manager.createSession(id: 'dup');
      final result = manager.createSession(id: 'dup');

      expect(result, isNull);
      expect(manager.sessionCount, 1);
    });

    test('getSession returns null for unknown ID', () {
      expect(manager.getSession('nope'), isNull);
    });

    test('destroySession returns true and removes session', () async {
      manager.createSession(id: 'doomed');

      final destroyed = await manager.destroySession('doomed');

      expect(destroyed, isTrue);
      expect(manager.getSession('doomed'), isNull);
      expect(manager.sessionCount, 0);
    });

    test('destroySession returns false for unknown ID', () async {
      final destroyed = await manager.destroySession('ghost');
      expect(destroyed, isFalse);
    });

    test('sessionIds lists all active sessions', () {
      manager
        ..createSession(id: 'a')
        ..createSession(id: 'b')
        ..createSession(id: 'c');

      expect(manager.sessionIds, containsAll(['a', 'b', 'c']));
    });

    test('disposeAll clears all sessions', () async {
      manager
        ..createSession(id: 'x')
        ..createSession(id: 'y');

      await manager.disposeAll();

      expect(manager.sessionCount, 0);
    });

    test('executeStateless produces result from mock', () async {
      const usage = MontyResourceUsage(
        memoryBytesUsed: 0,
        timeElapsedMs: 0,
        stackDepthUsed: 0,
      );

      final statelessManager = MontySessionManager(
        platformFactory: () {
          // The bridge calls start() with external functions, then
          // receives a complete progress.
          return MockMontyPlatform()
            ..enqueueProgress(
              const MontyComplete(
                result: MontyResult(value: 42, usage: usage),
              ),
            );
        },
      );

      final result = await statelessManager.executeStateless('2 + 2');

      expect(result.isError, isFalse);
    });
  });
}
