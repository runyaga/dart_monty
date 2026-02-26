import 'dart:convert';

import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:meta/meta.dart';

/// The internal function name used to restore state into Python globals.
const _restoreStateFn = '__restore_state__';

/// The internal function name used to persist state from Python globals.
const _persistStateFn = '__persist_state__';

/// Python preamble that restores persisted state into `globals()`.
///
/// Called at the start of every execution. The `__restore_state__()` external
/// function returns the JSON string stored by the previous call's postamble.
const _restorePreamble = '''
__s = __restore_state__()
if __s and __s != '{}':
    import json as __j
    for __k, __v in __j.loads(__s).items():
        globals()[__k] = __v
    del __j, __k, __v
del __s''';

/// Python postamble that serializes JSON-safe globals and persists them.
///
/// Called at the end of every successful execution. Variables starting with
/// `_` are excluded (covers dunders and conventional private names).
/// Non-JSON-serializable values are silently dropped.
const _persistPostamble = '''
import json as __j2
__state = {}
for __k2 in list(globals()):
    if not __k2.startswith('_'):
        __v2 = globals()[__k2]
        try:
            __j2.dumps(__v2)
            __state[__k2] = __v2
        except (TypeError, ValueError):
            pass
__persist_state__(__j2.dumps(__state))
del __j2, __state, __k2, __v2''';

/// A stateful execution session that persists variables across calls.
///
/// Each [MontySession] wraps a [MontyPlatform] instance and maintains
/// a JSON-serialized snapshot of Python globals between executions.
/// Only JSON-serializable types persist (int, float, str, bool, list,
/// dict, None). Non-serializable values (classes, functions, modules)
/// are silently dropped after each call.
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
  String _stateJson = '{}';
  bool _disposed = false;

  /// The current persisted state as a JSON-decoded map.
  ///
  /// Read-only snapshot. Returns an empty map if no state has been persisted.
  Map<String, Object?> get state =>
      Map<String, Object?>.from(jsonDecode(_stateJson) as Map<String, dynamic>);

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
    final wrappedCode = '$_restorePreamble\n$code\n$_persistPostamble';

    var progress = await _platform.start(
      wrappedCode,
      externalFunctions: [_restoreStateFn, _persistStateFn],
      limits: limits,
      scriptName: scriptName,
    );

    while (true) {
      switch (progress) {
        case MontyPending(functionName: _restoreStateFn):
          progress = await _platform.resume(_stateJson);

        case MontyPending(functionName: _persistStateFn):
          final args = progress.arguments;
          if (args.isNotEmpty) {
            _stateJson = args.first.toString();
          }
          progress = await _platform.resume(null);

        case MontyComplete(:final result):
          return result;

        case MontyPending():
          progress = await _platform.resumeWithError(
            'Unexpected external function in run() mode: '
            '${progress.functionName}',
          );

        case MontyResolveFutures():
          progress = await _platform.resume(null);
      }
    }
  }

  /// Clears all persisted state.
  ///
  /// After calling this, the next `run()` or `start()` call begins with
  /// empty globals (as if creating a fresh session).
  void clearState() {
    _checkNotDisposed();
    _stateJson = '{}';
  }

  /// Disposes the session.
  ///
  /// Clears persisted state. Does NOT dispose the underlying [MontyPlatform].
  void dispose() {
    _stateJson = '{}';
    _disposed = true;
  }

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _disposed;

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MontySession has been disposed.');
    }
  }
}
