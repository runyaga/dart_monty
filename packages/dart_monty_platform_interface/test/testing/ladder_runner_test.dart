import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('loadLadderFixtures', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ladder_test_');
      File('${tempDir.path}/tier_01_basics.json').writeAsStringSync(
        jsonEncode([
          {'id': 1, 'name': 'one', 'code': '1', 'expected': 1},
        ]),
      );
      File('${tempDir.path}/tier_02_vars.json').writeAsStringSync(
        jsonEncode([
          {'id': 2, 'name': 'two', 'code': 'x=2', 'expected': 2},
        ]),
      );
      // Non-JSON file should be ignored.
      File('${tempDir.path}/readme.txt').writeAsStringSync('ignore me');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('loads and sorts tier files', () {
      final tiers = loadLadderFixtures(tempDir);
      expect(tiers.length, 2);
      expect(tiers[0].$1, 'tier_01_basics');
      expect(tiers[1].$1, 'tier_02_vars');
      expect(tiers[0].$2.length, 1);
      expect(tiers[0].$2.first['id'], 1);
    });

    test('ignores non-JSON files', () {
      final tiers = loadLadderFixtures(tempDir);
      final names = tiers.map((t) => t.$1).toList();
      expect(names, isNot(contains('readme')));
    });
  });

  group('runSimpleFixture', () {
    test('calls run with scriptName and asserts result', () async {
      final mock = MockMontyPlatform()
        ..runResult = const MontyResult(
          value: 42,
          usage: MontyResourceUsage(
            memoryBytesUsed: 0,
            timeElapsedMs: 0,
            stackDepthUsed: 0,
          ),
        );

      await runSimpleFixture(mock, 'code', {
        'id': 1,
        'expected': 42,
        'scriptName': 'test.py',
      });

      expect(mock.lastRunCode, 'code');
      expect(mock.lastRunScriptName, 'test.py');
    });
  });

  group('runErrorFixture', () {
    test('catches MontyException and checks errorContains', () async {
      final mock = _ThrowingMock(
        const MontyException(
          message: 'name error: x is not defined',
          excType: 'NameError',
        ),
      );

      await runErrorFixture(mock, 'code', {
        'id': 1,
        'errorContains': 'not defined',
        'expectedExcType': 'NameError',
      });
    });

    test('fails when no exception thrown', () async {
      final mock = MockMontyPlatform()
        ..runResult = const MontyResult(
          usage: MontyResourceUsage(
            memoryBytesUsed: 0,
            timeElapsedMs: 0,
            stackDepthUsed: 0,
          ),
        );

      expect(
        () => runErrorFixture(mock, 'code', {'id': 1}),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('runIterativeFixture', () {
    test('handles resumeValues path', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fetch',
            arguments: ['url'],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: 'done',
              usage: MontyResourceUsage(
                memoryBytesUsed: 0,
                timeElapsedMs: 0,
                stackDepthUsed: 0,
              ),
            ),
          ),
        );

      await runIterativeFixture(mock, {
        'id': 1,
        'code': 'fetch("url")',
        'externalFunctions': ['fetch'],
        'resumeValues': ['response'],
        'expected': 'done',
        'expectedFnName': 'fetch',
      });

      expect(mock.startCodes, ['fetch("url")']);
      expect(mock.resumeReturnValues, ['response']);
    });

    test('handles resumeErrors path', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: 'fetch',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: 'fallback',
              usage: MontyResourceUsage(
                memoryBytesUsed: 0,
                timeElapsedMs: 0,
                stackDepthUsed: 0,
              ),
            ),
          ),
        );

      await runIterativeFixture(mock, {
        'id': 2,
        'code': 'try_fetch()',
        'externalFunctions': ['fetch'],
        'resumeErrors': ['network error'],
        'expected': 'fallback',
      });

      expect(mock.resumeErrorMessages, ['network error']);
    });
  });
}

/// A mock that throws a [MontyException] on [run].
class _ThrowingMock extends MockMontyPlatform {
  _ThrowingMock(this._exception);
  final MontyException _exception;

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    runCodes.add(code);
    runScriptNamesList.add(scriptName);
    throw _exception;
  }
}
