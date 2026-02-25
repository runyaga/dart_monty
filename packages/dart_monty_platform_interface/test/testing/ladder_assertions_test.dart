import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('assertLadderResult', () {
    test('exact match via expected', () {
      assertLadderResult(42, {'id': 1, 'expected': 42});
    });

    test('exact match with list', () {
      assertLadderResult([
        1,
        2,
        3,
      ], {
        'id': 2,
        'expected': [1, 2, 3],
      });
    });

    test('null value matches null expected', () {
      assertLadderResult(null, {'id': 3, 'expected': null});
    });

    test('expectedContains checks substring', () {
      assertLadderResult(
        'hello world',
        {'id': 4, 'expectedContains': 'world'},
      );
    });

    test('expectedSorted sorts lists before comparison', () {
      assertLadderResult(
        [3, 1, 2],
        {
          'id': 5,
          'expected': [2, 3, 1],
          'expectedSorted': true,
        },
      );
    });

    test('expectedSorted false does not sort', () {
      assertLadderResult(
        [1, 2, 3],
        {
          'id': 6,
          'expected': [1, 2, 3],
          'expectedSorted': false,
        },
      );
    });
  });

  group('assertPendingFields', () {
    test('checks expectedFnName', () {
      const pending = MontyPending(
        functionName: 'fetch',
        arguments: [],
      );
      assertPendingFields(pending, {'id': 1, 'expectedFnName': 'fetch'});
    });

    test('checks expectedArgs', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [1, 'two'],
      );
      assertPendingFields(pending, {
        'id': 2,
        'expectedArgs': [1, 'two'],
      });
    });

    test('checks expectedKwargs with map', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [],
        kwargs: {'key': 'val'},
      );
      assertPendingFields(pending, {
        'id': 3,
        'expectedKwargs': {'key': 'val'},
      });
    });

    test('checks expectedKwargs null', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [],
      );
      assertPendingFields(pending, {'id': 4, 'expectedKwargs': null});
    });

    test('checks expectedCallIdNonZero', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [],
        callId: 42,
      );
      assertPendingFields(
        pending,
        {'id': 5, 'expectedCallIdNonZero': true},
      );
    });

    test('checks expectedMethodCall', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [],
        methodCall: true,
      );
      assertPendingFields(
        pending,
        {'id': 6, 'expectedMethodCall': true},
      );
    });

    test('missing keys are no-ops', () {
      const pending = MontyPending(
        functionName: 'fn',
        arguments: [],
      );
      // No assertions fail when fixture has no expected* keys.
      assertPendingFields(pending, {'id': 7});
    });
  });

  group('assertExceptionFields', () {
    test('checks expectedExcType', () {
      const exc = MontyException(
        message: 'bad',
        excType: 'ValueError',
      );
      assertExceptionFields(exc, {'id': 1, 'expectedExcType': 'ValueError'});
    });

    test('checks expectedTracebackMinFrames', () {
      const exc = MontyException(
        message: 'bad',
        traceback: [
          MontyStackFrame(filename: 'a.py', startLine: 1, startColumn: 0),
          MontyStackFrame(filename: 'b.py', startLine: 2, startColumn: 0),
        ],
      );
      assertExceptionFields(
        exc,
        {'id': 2, 'expectedTracebackMinFrames': 2},
      );
    });

    test('checks expectedTracebackFrameHasFilename', () {
      const exc = MontyException(
        message: 'bad',
        traceback: [
          MontyStackFrame(
            filename: 'main.py',
            startLine: 1,
            startColumn: 0,
          ),
        ],
      );
      assertExceptionFields(
        exc,
        {'id': 3, 'expectedTracebackFrameHasFilename': true},
      );
    });

    test('checks expectedErrorFilename', () {
      const exc = MontyException(
        message: 'bad',
        filename: 'test.py',
      );
      assertExceptionFields(
        exc,
        {'id': 4, 'expectedErrorFilename': 'test.py'},
      );
    });

    test('checks expectedTracebackFilename', () {
      const exc = MontyException(
        message: 'bad',
        traceback: [
          MontyStackFrame(
            filename: 'other.py',
            startLine: 1,
            startColumn: 0,
          ),
          MontyStackFrame(
            filename: 'target.py',
            startLine: 5,
            startColumn: 0,
          ),
        ],
      );
      assertExceptionFields(
        exc,
        {'id': 5, 'expectedTracebackFilename': 'target.py'},
      );
    });

    test('missing keys are no-ops', () {
      const exc = MontyException(message: 'bad');
      // No assertions fail when fixture has no expected* keys.
      assertExceptionFields(exc, {'id': 6});
    });
  });
}
