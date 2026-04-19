import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/monty_runtime_state.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

MontyException _exception({
  String message = 'err',
  int? lineNumber,
  List<MontyStackFrame> traceback = const [],
}) => MontyException(
  message: message,
  lineNumber: lineNumber,
  traceback: traceback,
);

MontyStackFrame _frame(int startLine, {int? endLine}) => MontyStackFrame(
  filename: 'main.py',
  startLine: startLine,
  startColumn: 0,
  endLine: endLine,
  frameName: 'test',
);

void main() {
  // ---------------------------------------------------------------------------
  // restoreLineCount
  // ---------------------------------------------------------------------------

  group('restoreLineCount', () {
    test('empty state is 1 line (just __restore_state__() call)', () {
      expect(restoreLineCount({}), 1);
    });

    test('one variable adds one line', () {
      expect(restoreLineCount({'x': 1}), 2);
    });

    test('three variables adds three lines', () {
      expect(restoreLineCount({'a': 1, 'b': 2, 'c': 3}), 4);
    });
  });

  // ---------------------------------------------------------------------------
  // adjustRestoreOffset
  // ---------------------------------------------------------------------------

  group('adjustRestoreOffset', () {
    test('zero offset returns exception unchanged', () {
      final e = _exception(lineNumber: 5);
      expect(adjustRestoreOffset(e, 0), same(e));
    });

    test('negative offset returns exception unchanged', () {
      final e = _exception(lineNumber: 5);
      expect(adjustRestoreOffset(e, -1), same(e));
    });

    test('adjusts lineNumber by offset', () {
      final e = _exception(lineNumber: 6);
      final adjusted = adjustRestoreOffset(e, 2);
      expect(adjusted.lineNumber, 4);
    });

    test('lineNumber clamps to 1 when offset exceeds line', () {
      final e = _exception(lineNumber: 2);
      final adjusted = adjustRestoreOffset(e, 5);
      expect(adjusted.lineNumber, 1);
    });

    test('null lineNumber stays null', () {
      final e = _exception();
      final adjusted = adjustRestoreOffset(e, 3);
      expect(adjusted.lineNumber, isNull);
    });

    test('filters traceback frames at or below offset', () {
      final e = _exception(
        lineNumber: 5,
        traceback: [_frame(1), _frame(3), _frame(5)],
      );
      final adjusted = adjustRestoreOffset(e, 2);
      // Frame at line 1 and line 3 are at/below offset=2 — only frame at 3
      // has startLine > 2, so only it (and line 5) survive.
      expect(adjusted.traceback.length, 2);
      expect(adjusted.traceback[0].startLine, 1); // 3 - 2 = 1
      expect(adjusted.traceback[1].startLine, 3); // 5 - 2 = 3
    });

    test('adjusts frame endLine when present', () {
      final frame = _frame(4, endLine: 6);
      final e = _exception(lineNumber: 4, traceback: [frame]);
      final adjusted = adjustRestoreOffset(e, 2);
      expect(adjusted.traceback.first.endLine, 4); // 6 - 2
    });

    test('null frame endLine stays null', () {
      final frame = _frame(4);
      final e = _exception(lineNumber: 4, traceback: [frame]);
      final adjusted = adjustRestoreOffset(e, 2);
      expect(adjusted.traceback.first.endLine, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // extractBridgeResult
  // ---------------------------------------------------------------------------

  group('extractBridgeResult', () {
    test('returns value from BridgeRunFinished', () {
      final events = <BridgeEvent>[
        const BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: 42,
        ),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.value.dartValue, 42);
      expect(result.error, isNull);
    });

    test('returns error from BridgeRunError', () {
      final events = <BridgeEvent>[
        const BridgeRunError(message: 'kaboom'),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.error, isNotNull);
      expect(result.error!.message, 'kaboom');
    });

    test('uses BridgeRunError.exception when present', () {
      const exc = MontyException(message: 'typed', lineNumber: 3);
      final events = <BridgeEvent>[
        const BridgeRunError(message: 'kaboom', exception: exc),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.error!.message, 'typed');
    });

    test('applies restoreOffset to exception lineNumber', () {
      const exc = MontyException(message: 'err', lineNumber: 5);
      final events = <BridgeEvent>[
        const BridgeRunError(message: 'err', exception: exc),
      ];
      final result = extractBridgeResult(events, 2);
      expect(result.error!.lineNumber, 3);
    });

    test('uses last terminal event when multiple events present', () {
      final events = <BridgeEvent>[
        const BridgeRunFinished(threadId: 't', runId: 'r', value: 1),
        const BridgeRunFinished(threadId: 't', runId: 'r', value: 99),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.value.dartValue, 99);
    });

    test('preserves printOutput from BridgeRunFinished', () {
      final events = <BridgeEvent>[
        const BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          printOutput: 'hello\n',
        ),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.printOutput, 'hello\n');
    });

    test('throws StateError when no terminal event', () {
      expect(
        () => extractBridgeResult([], 0),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // generateRestoreCode
  // ---------------------------------------------------------------------------

  group('generateRestoreCode', () {
    test('empty state generates only the restore call', () {
      final code = generateRestoreCode({});
      expect(code, '__d = __restore_state__()');
    });

    test('one variable adds one assignment line', () {
      final code = generateRestoreCode({'x': 1});
      expect(code, '__d = __restore_state__()\nx = __d["x"]');
    });

    test('multiple variables generate one line each', () {
      final code = generateRestoreCode({'a': 1, 'b': 2});
      expect(code, contains('a = __d["a"]'));
      expect(code, contains('b = __d["b"]'));
    });
  });

  // ---------------------------------------------------------------------------
  // generatePersistCode
  // ---------------------------------------------------------------------------

  group('generatePersistCode', () {
    test('empty state and no assignments generates empty persist call', () {
      final code = generatePersistCode('pass', {});
      expect(code, '__persist_state__({})');
    });

    test('assignment in userCode is captured', () {
      final code = generatePersistCode('x = 42', {});
      expect(code, contains('__d2["x"] = x'));
    });

    test('existing state key is captured', () {
      final code = generatePersistCode('pass', {'y': 1});
      expect(code, contains('__d2["y"] = y'));
    });

    test('generated code has NameError guard', () {
      final code = generatePersistCode('x = 1', {});
      expect(code, contains('except NameError:'));
    });

    test('ends with persist call', () {
      final code = generatePersistCode('x = 1', {});
      expect(code, endsWith('__persist_state__(__d2)'));
    });
  });

  // ---------------------------------------------------------------------------
  // wrapSandboxed — ReplPlatform backing: returns code unchanged
  // ---------------------------------------------------------------------------

  group('wrapSandboxed', () {
    test('returns user code unchanged', () {
      const input = 'x = 1';
      final code = wrapSandboxed(input);
      expect(code, input);
    });

    test('expression code returned unchanged — no __r capture', () {
      const input = '1 + 1';
      final code = wrapSandboxed(input);
      expect(code, input);
      expect(code, isNot(contains('__r')));
    });

    test('state argument ignored — no restore preamble', () {
      final code = wrapSandboxed('pass');
      expect(code, isNot(contains('__restore_state__')));
      expect(code, isNot(contains('__persist_state__')));
    });
  });

  // ---------------------------------------------------------------------------
  // wrapShared — ReplPlatform backing: returns code unchanged
  // ---------------------------------------------------------------------------

  group('wrapShared', () {
    test('returns user code unchanged', () {
      const input = 'x = 1';
      final code = wrapShared(input);
      expect(code, input);
    });

    test('expression code returned unchanged — no __r capture', () {
      const input = '1 + 1';
      final code = wrapShared(input);
      expect(code, input);
      expect(code, isNot(contains('__r')));
    });

    test('no restore preamble emitted', () {
      final code = wrapShared('x = 1');
      expect(code, isNot(contains('__restore_state__')));
    });

    test('no persist epilogue emitted', () {
      final code = wrapShared('x = 1');
      expect(code, isNot(contains('__persist_state__')));
    });
  });
}
