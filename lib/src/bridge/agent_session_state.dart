import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Python name of the host function that restores serialized session state.
const restoreFn = '__restore_state__';

/// Python name of the host function that persists session state to Dart.
const persistFn = '__persist_state__';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

/// Number of lines the state restore preamble adds before user code.
///
/// Structure:
///   __d = __restore_state__()   ← always 1 line
///   x = __d["x"]               ← 1 line per state variable
///   [user code]
int restoreLineCount(Map<String, Object?> state) => 1 + state.keys.length;

/// Adjusts [e] line numbers by subtracting [offset] lines added by the state
/// restore preamble, so errors point to user code lines, not wrapped lines.
MontyException adjustRestoreOffset(MontyException e, int offset) {
  if (offset <= 0) return e;

  return MontyException(
    message: e.message,
    filename: e.filename,
    lineNumber: e.lineNumber != null
        ? (e.lineNumber! - offset).clamp(1, e.lineNumber!)
        : null,
    columnNumber: e.columnNumber,
    sourceCode: e.sourceCode,
    excType: e.excType,
    traceback: e.traceback
        .where((f) => f.startLine > offset)
        .map(
          (f) => MontyStackFrame(
            filename: f.filename,
            startLine: (f.startLine - offset).clamp(1, f.startLine),
            startColumn: f.startColumn,
            endLine: f.endLine != null
                ? (f.endLine! - offset).clamp(1, f.endLine!)
                : null,
            endColumn: f.endColumn,
            frameName: f.frameName,
            previewLine: f.previewLine,
            hideCaret: f.hideCaret,
            hideFrameName: f.hideFrameName,
          ),
        )
        .toList(),
  );
}

/// Extracts the terminal [MontyResult] from a completed bridge event list,
/// adjusting exception line numbers by [restoreOffset] to account for the
/// state restore preamble injected before user code.
///
/// Throws [StateError] if no [BridgeRunFinished]/[BridgeRunError] event exists.
MontyResult extractBridgeResult(
  List<BridgeEvent> events,
  int restoreOffset,
) {
  for (final event in events.reversed) {
    if (event is BridgeRunFinished) {
      return MontyResult(
        value: MontyValue.fromDart(event.value),
        usage: _zeroUsage,
        printOutput: event.printOutput,
      );
    }
    if (event is BridgeRunError) {
      final raw = event.exception ?? MontyException(message: event.message);
      final adjusted = adjustRestoreOffset(raw, restoreOffset);

      return MontyResult(
        value: const MontyNone(),
        error: adjusted,
        usage: _zeroUsage,
        printOutput: event.printOutput,
      );
    }
  }

  throw StateError('No terminal event in bridge execution');
}

/// Generates the `__restore_state__` preamble that loads [state] into Python.
String generateRestoreCode(Map<String, Object?> state) {
  final buf = StringBuffer('__d = $restoreFn()');
  for (final key in state.keys) {
    buf.write('\n$key = __d["$key"]');
  }

  return buf.toString();
}

/// Generates the `__persist_state__` epilogue that captures [userCode]
/// assignment targets plus existing [state] keys back to Dart.
String generatePersistCode(String userCode, Map<String, Object?> state) {
  final names = <String>{...state.keys, ...extractAssignmentTargets(userCode)};

  if (names.isEmpty) return '$persistFn({})';

  final buf = StringBuffer('__d2 = {}');
  for (final name in names) {
    buf
      ..write('\ntry:')
      ..write('\n    __d2["$name"] = $name')
      ..write('\nexcept NameError:')
      ..write('\n    pass');
  }
  buf.write('\n$persistFn(__d2)');

  return buf.toString();
}

/// Wraps [userCode] with restore/persist state bookkeeping, preserving
/// the last-expression result capture.
String wrapWithStateCode(String userCode, Map<String, Object?> state) {
  final restore = generateRestoreCode(state);
  final persist = generatePersistCode(userCode, state);
  final (processed, hasResult) = captureLastExpression(userCode);

  final buf = StringBuffer(restore)
    ..write('\n')
    ..write(processed)
    ..write('\n')
    ..write(persist);

  if (hasResult) buf.write('\n__r');

  return buf.toString();
}
