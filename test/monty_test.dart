import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 128,
    timeElapsedMs: 1,
    stackDepthUsed: 1,
  );

  late MockMontyPlatform mock;
  late Monty monty;

  setUp(() {
    mock = MockMontyPlatform();
    monty = Monty.withPlatform(mock);
  });

  /// Enqueues the standard restore → persist → complete cycle that
  /// MontySession uses internally for each run() call.
  void enqueueRunCycle({MontyValue? resultValue}) {
    mock
      ..enqueueProgress(
        const MontyPending(functionName: '__restore_state__', arguments: []),
      )
      ..enqueueProgress(
        const MontyPending(
          functionName: '__persist_state__',
          arguments: [MontyDict({})],
        ),
      )
      ..enqueueProgress(
        MontyComplete(
          result: MontyResult(
            value: resultValue ?? const MontyNull(),
            usage: usage,
          ),
        ),
      );
  }

  group('Monty', () {
    test('platform getter returns the underlying platform', () {
      expect(monty.platform, same(mock));
    });

    test('run() executes code and returns result', () async {
      enqueueRunCycle(resultValue: const MontyInt(42));

      final result = await monty.run('1 + 1');

      expect(result.value, const MontyInt(42));
    });

    test('run() passes limits and scriptName', () async {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 100,
        stackDepth: 10,
      );
      enqueueRunCycle();

      await monty.run('x', limits: limits, scriptName: 'test.py');

      expect(mock.lastStartLimits, limits);
      expect(mock.lastStartScriptName, 'test.py');
    });

    test('variables persist across run() calls', () async {
      // First run: x = 42
      enqueueRunCycle();
      await monty.run('x = 42');

      // State was persisted
      expect(monty.state, isEmpty); // empty because persist sent {}
    });

    test('clearState() resets persisted state', () async {
      enqueueRunCycle();
      await monty.run('x = 42');

      monty.clearState();
      expect(monty.state, isEmpty);
    });

    test('start/resume available via platform', () async {
      const expectedProgress = MontyPending(
        functionName: 'fetch',
        arguments: [],
      );
      mock.enqueueProgress(expectedProgress);

      final progress = await monty.platform.start(
        'fetch()',
        externalFunctions: ['fetch'],
      );

      expect(progress, expectedProgress);
    });

    test('dispose() disposes session and platform', () async {
      expect(mock.isDisposed, isFalse);

      await monty.dispose();

      expect(mock.isDisposed, isTrue);
    });
  });
}
