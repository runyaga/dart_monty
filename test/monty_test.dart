import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_testing.dart';
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

  group('Monty delegation', () {
    test('platform getter returns the underlying platform', () {
      expect(monty.platform, same(mock));
    });

    test('run() delegates to platform', () async {
      const expected = MontyResult(value: MontyInt(42), usage: usage);
      mock.runResult = expected;

      final result = await monty.run('1 + 1');

      expect(result, expected);
      expect(mock.lastRunCode, '1 + 1');
    });

    test('run() passes limits and scriptName', () async {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 100,
        stackDepth: 10,
      );
      mock.runResult = const MontyResult(usage: usage);

      await monty.run('x', limits: limits, scriptName: 'test.py');

      expect(mock.lastRunLimits, limits);
      expect(mock.lastRunScriptName, 'test.py');
    });

    test('start() delegates to platform', () async {
      const expectedProgress = MontyPending(
        functionName: 'fetch',
        arguments: [],
      );
      mock.enqueueProgress(expectedProgress);

      final progress = await monty.start(
        'fetch()',
        externalFunctions: ['fetch'],
      );

      expect(progress, expectedProgress);
      expect(mock.lastStartCode, 'fetch()');
      expect(mock.lastStartExternalFunctions, ['fetch']);
    });

    test('start() passes limits and scriptName', () async {
      const limits = MontyLimits(
        memoryBytes: 2048,
        timeoutMs: 200,
        stackDepth: 20,
      );
      mock.enqueueProgress(
        const MontyComplete(result: MontyResult(usage: usage)),
      );

      await monty.start('x', limits: limits, scriptName: 'app.py');

      expect(mock.lastStartLimits, limits);
      expect(mock.lastStartScriptName, 'app.py');
    });

    test('resume() delegates to platform', () async {
      const expectedProgress = MontyComplete(
        result: MontyResult(value: MontyString('done'), usage: usage),
      );
      mock.enqueueProgress(expectedProgress);

      final progress = await monty.resume('return_value');

      expect(progress, expectedProgress);
      expect(mock.lastResumeReturnValue, 'return_value');
    });

    test('resumeWithError() delegates to platform', () async {
      const expectedProgress = MontyComplete(
        result: MontyResult(usage: usage),
      );
      mock.enqueueProgress(expectedProgress);

      final progress = await monty.resumeWithError('something failed');

      expect(progress, expectedProgress);
      expect(mock.lastResumeErrorMessage, 'something failed');
    });

    test('dispose() delegates to platform', () async {
      expect(mock.isDisposed, isFalse);

      await monty.dispose();

      expect(mock.isDisposed, isTrue);
    });
  });
}
