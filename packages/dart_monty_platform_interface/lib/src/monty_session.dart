import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_resource_usage.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:meta/meta.dart';

/// The internal function name used to restore state into Python globals.
const _restoreStateFn = '__restore_state__';

/// The internal function name used to persist state from Python globals.
const _persistStateFn = '__persist_state__';

/// Matches simple assignment targets: `identifier = ...`
///
/// Only captures a single identifier before `=`.
/// Excludes `==` (comparison) and augmented assignments (`+=`, etc.).
final _assignmentPattern = RegExp(r'^([a-zA-Z]\w*)\s*=[^=]', multiLine: true);

/// Zero-cost usage for error results synthesized from caught exceptions.
const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

/// Python keyword prefixes that indicate a line is a statement (not an
/// expression). Used to detect the user code's last expression so it can
/// be captured before the persist postamble runs.
const _statementPrefixes = [
  'if ',
  'for ',
  'while ',
  'with ',
  'try:',
  'def ',
  'class ',
  'import ',
  'from ',
  'raise ',
  'return ',
  'pass',
  'break',
  'continue',
  'assert ',
];

/// A stateful execution session that persists variables across calls.
///
/// Each [MontySession] wraps a [MontyPlatform] instance and maintains
/// a snapshot of Python globals between executions. Only JSON-serializable
/// types persist (int, float, str, bool, list, dict, None).
/// Non-serializable values are silently dropped after each call.
///
/// ```dart
/// final session = MontySession(platform: monty);
/// await session.run('x = 42');
/// final result = await session.run('x + 1');
/// print(result.value); // 43
/// ```
class MontySession {
  /// Creates a [MontySession] wrapping the given [platform].
  ///
  /// The session does not take ownership of the platform — calling
  /// [dispose] on the session does NOT dispose the underlying platform.
  MontySession({required MontyPlatform platform}) : _platform = platform;

  final MontyPlatform _platform;
  Map<String, Object?> _state = {};
  bool _disposed = false;

  /// The current persisted state as a JSON-decoded map.
  ///
  /// Read-only snapshot. Returns an empty map if no state has been persisted.
  Map<String, Object?> get state => Map<String, Object?>.from(_state);

  /// Executes [code] with state restored from previous calls.
  ///
  /// Returns the [MontyResult] from execution. Variables defined in
  /// [code] persist for subsequent calls (if JSON-serializable).
  ///
  /// Internal external functions (`__restore_state__`, `__persist_state__`)
  /// are handled transparently. Any other external function call causes
  /// an error — use `start()` for code that calls external functions.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    _checkNotDisposed();
    final wrappedCode = _wrapCode(code);

    var progress = await _safeStart(
      wrappedCode,
      externalFunctions: [_restoreStateFn, _persistStateFn],
      limits: limits,
      scriptName: scriptName,
    );

    while (true) {
      switch (progress) {
        case MontyPending(functionName: _restoreStateFn):
          progress = await _safeResume(_state);

        case MontyPending(functionName: _persistStateFn):
          _capturePersistArgs(progress.arguments);
          progress = await _safeResume(null);

        case MontyComplete(:final result):
          return result;

        case MontyPending():
          progress = await _safeResumeWithError(
            'Unexpected external function in run() mode: '
            '${progress.functionName}',
          );

        case MontyResolveFutures():
          progress = await _safeResume(null);
      }
    }
  }

  /// Starts iterative execution of [code] with state restore/persist.
  ///
  /// Same as [MontyPlatform.start] but with state management injected.
  /// Internal functions (`__restore_state__`, `__persist_state__`) are
  /// handled transparently — only user external functions are returned
  /// as [MontyPending] to the caller.
  ///
  /// The caller must resume through [resume] or [resumeWithError] on
  /// this session (not on the underlying platform) so that internal
  /// state functions are intercepted on completion.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    _checkNotDisposed();
    final wrappedCode = _wrapCode(code);
    final allExtFns = [
      _restoreStateFn,
      _persistStateFn,
      ...?externalFunctions,
    ];

    final progress = await _safeStart(
      wrappedCode,
      externalFunctions: allExtFns,
      limits: limits,
      scriptName: scriptName,
    );

    return _interceptProgress(progress);
  }

  /// Resumes a paused execution with [returnValue].
  ///
  /// Must be used instead of [MontyPlatform.resume] so that internal
  /// state functions are intercepted transparently.
  Future<MontyProgress> resume(Object? returnValue) async {
    _checkNotDisposed();
    final progress = await _safeResume(returnValue);

    return _interceptProgress(progress);
  }

  /// Resumes a paused execution by raising an error with [errorMessage].
  ///
  /// Must be used instead of [MontyPlatform.resumeWithError] so that
  /// internal state functions are intercepted transparently.
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _checkNotDisposed();
    final progress = await _safeResumeWithError(errorMessage);

    return _interceptProgress(progress);
  }

  /// Clears all persisted state.
  ///
  /// After calling this, the next `run()` or `start()` call begins with
  /// empty globals (as if creating a fresh session).
  void clearState() {
    _checkNotDisposed();
    _state = {};
  }

  /// Disposes the session.
  ///
  /// Clears persisted state. Does NOT dispose the underlying [MontyPlatform].
  void dispose() {
    _state = {};
    _disposed = true;
  }

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _disposed;

  // ---------------------------------------------------------------------------
  // Code generation
  // ---------------------------------------------------------------------------

  /// Wraps [userCode] with restore preamble and persist postamble.
  ///
  /// If the user code's last line is an expression (not a statement),
  /// it is captured in `__r` so the persist postamble doesn't overwrite
  /// the result value. After persistence, `__r` is re-emitted as the
  /// final expression so `MontyResult.value` reflects the user's code.
  String _wrapCode(String userCode) {
    final restore = _generateRestore();
    final persist = _generatePersist(userCode);
    final (processedCode, hasResult) = _captureLastExpression(userCode);

    final buf = StringBuffer(restore)
      ..write('\n')
      ..write(processedCode)
      ..write('\n')
      ..write(persist);

    if (hasResult) {
      buf.write('\n__r');
    }

    return buf.toString();
  }

  /// Generates Python code to restore state from the `__restore_state__`
  /// external function.
  ///
  /// The function returns the current state as a Python dict. Each known
  /// key is unpacked into a local variable assignment.
  String _generateRestore() {
    final buf = StringBuffer('__d = __restore_state__()');
    for (final key in _state.keys) {
      buf.write('\n$key = __d["$key"]');
    }

    return buf.toString();
  }

  /// Generates Python code to persist state via `__persist_state__`.
  ///
  /// Builds a dict of all known variable names (previous state keys +
  /// new assignment targets from [userCode]), using try/except per
  /// variable to gracefully skip undefined or non-serializable values.
  String _generatePersist(String userCode) {
    final names = <String>{
      ..._state.keys,
      ..._extractAssignmentTargets(userCode),
    };

    if (names.isEmpty) {
      return '__persist_state__({})';
    }

    final buf = StringBuffer('__d2 = {}');
    for (final name in names) {
      buf
        ..write('\ntry:')
        ..write('\n    __d2["$name"] = $name')
        ..write('\nexcept Exception:')
        ..write('\n    pass');
    }
    buf.write('\n__persist_state__(__d2)');

    return buf.toString();
  }

  /// Checks whether [line] looks like a Python expression (not a statement).
  ///
  /// Returns `false` for lines starting with known statement keywords,
  /// assignments (`name = ...`), or empty/comment lines.
  static bool _isExpression(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return false;

    for (final prefix in _statementPrefixes) {
      if (trimmed.startsWith(prefix) || trimmed == prefix.trim()) return false;
    }

    // Simple assignment: `identifier = ...` (not `==`)
    if (_assignmentPattern.hasMatch(trimmed)) return false;

    return true;
  }

  /// Processes [userCode] to capture the last expression's value.
  ///
  /// If the last non-empty line is an expression, replaces it with
  /// `__r = (expression)` and returns `(modifiedCode, true)`.
  /// After the persist postamble, `__r` is re-emitted so
  /// `MontyResult.value` reflects the user's expression.
  ///
  /// If the last line is a statement (or there is no code), returns
  /// `(userCode, false)`.
  static (String, bool) _captureLastExpression(String userCode) {
    final lines = userCode.split('\n');

    // Find last non-empty, non-comment line index.
    var lastIdx = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
      final trimmed = lines[i].trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        lastIdx = i;
        break;
      }
    }

    if (lastIdx < 0) return (userCode, false);

    if (!_isExpression(lines[lastIdx])) return (userCode, false);

    // Replace last expression with `__r = (expression)`
    final expr = lines[lastIdx];
    lines[lastIdx] = '__r = ($expr)';

    return (lines.join('\n'), true);
  }

  /// Extracts simple assignment targets from [code].
  ///
  /// Returns variable names from top-level `identifier = expression`
  /// patterns. Excludes names starting with `_` (dunder/private).
  @visibleForTesting
  static Set<String> extractAssignmentTargets(String code) =>
      _extractAssignmentTargets(code);

  static Set<String> _extractAssignmentTargets(String code) {
    final names = <String>{};
    for (final line in code.split('\n')) {
      // Only process top-level lines (no leading whitespace).
      if (line.isNotEmpty && line[0] != ' ' && line[0] != '\t') {
        // Split by semicolons to handle multi-statement lines
        // like `x = 1; y = 2; z = 3`.
        for (final segment in line.split(';')) {
          final trimmed = segment.trimLeft();
          final match = _assignmentPattern.firstMatch(trimmed);
          if (match != null) {
            final name = match.group(1)!;
            if (!name.startsWith('_')) {
              names.add(name);
            }
          }
        }
      }
    }

    return names;
  }

  // ---------------------------------------------------------------------------
  // State interception
  // ---------------------------------------------------------------------------

  /// Intercepts internal state functions, passing through user progress.
  Future<MontyProgress> _interceptProgress(MontyProgress progress) async {
    var current = progress;
    while (true) {
      switch (current) {
        case MontyPending(functionName: _restoreStateFn):
          current = await _safeResume(_state);

        case MontyPending(functionName: _persistStateFn):
          _capturePersistArgs(current.arguments);
          current = await _safeResume(null);

        case MontyComplete():
        case MontyPending():
        case MontyResolveFutures():
          return current;
      }
    }
  }

  /// Captures persisted state from `__persist_state__` arguments.
  void _capturePersistArgs(List<Object?> arguments) {
    if (arguments.isEmpty) return;
    final arg = arguments.first;
    if (arg is Map) {
      _state = Map<String, Object?>.from(arg);
    }
  }

  // ---------------------------------------------------------------------------
  // Safe platform wrappers
  // ---------------------------------------------------------------------------

  /// Wraps [MontyPlatform.start], catching [MontyException] thrown for
  /// Python runtime errors during `start()`/`resume()` and converting
  /// them to [MontyComplete] with an error result.
  Future<MontyProgress> _safeStart(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    try {
      return await _platform.start(
        code,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      );
    } on MontyException catch (e) {
      return MontyComplete(result: MontyResult(error: e, usage: _zeroUsage));
    }
  }

  /// Wraps [MontyPlatform.resume], catching [MontyException].
  Future<MontyProgress> _safeResume(Object? returnValue) async {
    try {
      return await _platform.resume(returnValue);
    } on MontyException catch (e) {
      return MontyComplete(result: MontyResult(error: e, usage: _zeroUsage));
    }
  }

  /// Wraps [MontyPlatform.resumeWithError], catching [MontyException].
  Future<MontyProgress> _safeResumeWithError(String errorMessage) async {
    try {
      return await _platform.resumeWithError(errorMessage);
    } on MontyException catch (e) {
      return MontyComplete(result: MontyResult(error: e, usage: _zeroUsage));
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MontySession has been disposed.');
    }
  }
}
