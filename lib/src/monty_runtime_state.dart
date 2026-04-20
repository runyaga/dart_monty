// ignore_for_file: avoid-non-null-assertion, binary-expression-operand-order
import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

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
