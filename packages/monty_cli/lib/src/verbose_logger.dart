import 'dart:io';

/// Logs detailed lifecycle events to stderr when verbose mode is active.
///
/// All output goes to stderr with `[MONTY]` prefix, keeping stdout clean
/// for machine-readable output. Traces component boundaries across:
/// - Isolate initialization
/// - Session state restore/persist
/// - Code execution
/// - Resource usage
class VerboseLogger {
  /// Creates a [VerboseLogger]. Pass `enabled: false` to create a no-op.
  const VerboseLogger({required this.enabled});

  /// Whether logging is active.
  final bool enabled;

  /// Logs isolate initialization.
  void logInit() {
    if (!enabled) return;
    _log('init isolate');
  }

  /// Logs the start of a session run.
  void logRun(String code) {
    if (!enabled) return;
    final preview = _truncate(code.replaceAll('\n', r'\n'), 60);
    _log('run code="$preview"');
  }

  /// Logs state restore with the number of variables.
  void logStateRestore(int variableCount) {
    if (!enabled) return;
    _log('state restore vars=$variableCount');
  }

  /// Logs state persist with variable names.
  void logStatePersist(Iterable<String> variableNames) {
    if (!enabled) return;
    _log('state persist vars=[${variableNames.join(", ")}]');
  }

  /// Logs execution result with resource usage.
  void logResult({
    required int memoryBytes,
    required int timeMs,
    required int stackDepth,
    required bool isError,
  }) {
    if (!enabled) return;
    final status = isError ? 'error' : 'ok';
    _log(
      'result status=$status '
      'memory=${memoryBytes}B time=${timeMs}ms stack=$stackDepth',
    );
  }

  /// Logs a session dispose.
  void logDispose() {
    if (!enabled) return;
    _log('dispose');
  }

  /// Logs a custom event.
  void log(String message) {
    if (!enabled) return;
    _log(message);
  }

  static void _log(String message) {
    stderr.writeln('[MONTY] $message');
  }

  static String _truncate(String s, int maxLength) {
    if (s.length <= maxLength) return s;

    return '${s.substring(0, maxLength - 3)}...';
  }
}
