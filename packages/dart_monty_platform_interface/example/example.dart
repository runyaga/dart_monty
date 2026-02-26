// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Demonstrates the platform interface types.
///
/// This package defines the abstract contract and shared types — use
/// `dart_monty` for a concrete implementation that runs Python code.
void main() {
  _resultFromJson();
  _resultWithError();
  _exceptionWithTraceback();
  _resourceUsage();
  _limits();
  _progressPatternMatching();
}

/// Construct a successful result from JSON.
void _resultFromJson() {
  final result = MontyResult.fromJson(const {
    'value': 42,
    'usage': {
      'memory_bytes_used': 1024,
      'time_elapsed_ms': 5,
      'stack_depth_used': 2,
    },
  });

  print('Value: ${result.value}'); // 42
  print('Memory: ${result.usage.memoryBytesUsed} bytes');
  print('Is error: ${result.isError}'); // false
}

/// Construct a result containing a Python error.
void _resultWithError() {
  final result = MontyResult.fromJson(const {
    'error': {
      'message': 'division by zero',
      'exc_type': 'ZeroDivisionError',
      'filename': '<expr>',
      'line_number': 1,
      'column_number': 2,
    },
    'usage': {
      'memory_bytes_used': 512,
      'time_elapsed_ms': 1,
      'stack_depth_used': 1,
    },
  });

  print('Is error: ${result.isError}'); // true
  print('Error type: ${result.error!.excType}'); // ZeroDivisionError
  print('Message: ${result.error!.message}'); // division by zero
}

/// Construct an exception with traceback frames.
void _exceptionWithTraceback() {
  const error = MontyException(
    message: "name 'x' is not defined",
    excType: 'NameError',
    filename: 'script.py',
    lineNumber: 5,
    columnNumber: 10,
    traceback: [
      MontyStackFrame(
        filename: 'script.py',
        startLine: 5,
        startColumn: 10,
        frameName: '<module>',
        previewLine: '    return x + 1',
      ),
      MontyStackFrame(
        filename: 'script.py',
        startLine: 2,
        startColumn: 4,
        frameName: 'compute',
      ),
    ],
  );

  print('Exception: ${error.excType}: ${error.message}');
  for (final frame in error.traceback) {
    print('  ${frame.filename}:${frame.startLine} in ${frame.frameName}');
  }
}

/// Construct resource usage directly.
void _resourceUsage() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 2048,
    timeElapsedMs: 10,
    stackDepthUsed: 3,
  );

  print('Memory: ${usage.memoryBytesUsed} bytes');
  print('Time: ${usage.timeElapsedMs} ms');
  print('Stack: ${usage.stackDepthUsed}');
}

/// Construct limits with optional fields.
void _limits() {
  const limits = MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
    stackDepth: 100,
  );

  print('Timeout: ${limits.timeoutMs} ms');
  print('Memory limit: ${limits.memoryBytes} bytes');
  print('Stack limit: ${limits.stackDepth}');
}

/// Use pattern matching on the MontyProgress sealed type.
void _progressPatternMatching() {
  // Simulate a pending external function call.
  const MontyProgress pending = MontyPending(
    functionName: 'fetch',
    arguments: ['https://api.example.com/data'],
    kwargs: {'timeout': 30},
    callId: 1,
  );

  // Simulate a completed execution.
  const MontyProgress complete = MontyComplete(
    result: MontyResult(
      value: 42,
      usage: MontyResourceUsage(
        memoryBytesUsed: 1024,
        timeElapsedMs: 5,
        stackDepthUsed: 2,
      ),
    ),
  );

  // Simulate a futures resolution request.
  const MontyProgress futures = MontyResolveFutures(
    pendingCallIds: [1, 2, 3],
  );

  // Exhaustive pattern matching on the sealed type.
  for (final progress in [pending, complete, futures]) {
    switch (progress) {
      case MontyPending(:final functionName, :final arguments, :final kwargs):
        print('Pending: $functionName($arguments, kwargs: $kwargs)');
      case MontyComplete(:final result):
        print('Complete: ${result.value}');
      case MontyResolveFutures(:final pendingCallIds):
        print('Resolve futures: $pendingCallIds');
    }
  }
}
