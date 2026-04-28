import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/runtime/runtime_state.dart';
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

    test('preserves typed MontyValue (regression for #384)', () {
      // event.value is the dartValue (a Map for MontyDataclass) which
      // would normally re-parse as MontyDict via fromDart. The
      // montyValue field carries the typed value through losslessly.
      const dataclass = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {
          'name': MontyString('alice'),
          'age': MontyInt(30),
        },
      );
      final events = <BridgeEvent>[
        BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: dataclass.dartValue,
          montyValue: dataclass,
        ),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.value, isA<MontyDataclass>());
      expect((result.value as MontyDataclass).name, 'User');
    });

    test('falls back to fromDart when montyValue absent', () {
      // External bridge implementations that don't set montyValue
      // still get a MontyDict from a Map event.value — backwards
      // compatible behaviour.
      final events = <BridgeEvent>[
        const BridgeRunFinished(
          threadId: 't',
          runId: 'r',
          value: {'k': 1},
        ),
      ];
      final result = extractBridgeResult(events, 0);
      expect(result.value, isA<MontyDict>());
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
}
