import 'dart:async';

import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/platform/code_capture.dart' as code_capture;
import 'package:dart_monty/src/platform/monty_error.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:meta/meta.dart';
import 'package:signals_core/signals_core.dart';

/// The internal function name used to restore state into Python globals.
const _restoreStateFn = '__restore_state__';

/// The internal function name used to persist state from Python globals.
const _persistStateFn = '__persist_state__';

/// Zero-cost usage for error results synthesized from caught exceptions.
const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

// ---------------------------------------------------------------------------
// MontySessionLifecycle — sealed lifecycle state for MontySession.
// ---------------------------------------------------------------------------

/// The lifecycle state of a [MontySession].
///
/// Use exhaustive pattern matching or `lifecycleSignal` for reactive
/// observation:
/// ```dart
/// effect(() {
///   switch (session.lifecycleSignal.value) {
///     case MontySessionActive(): // session is live
///     case MontySessionDisposed(): // session was disposed
///   }
/// });
/// ```
sealed class MontySessionLifecycle {
  /// Creates a [MontySessionLifecycle].
  const MontySessionLifecycle();
}

/// The session is active and accepting `run()` calls.
final class MontySessionActive extends MontySessionLifecycle {
  /// Creates a [MontySessionActive].
  const MontySessionActive();
}

/// The session has been disposed and no longer accepts calls.
final class MontySessionDisposed extends MontySessionLifecycle {
  /// Creates a [MontySessionDisposed].
  const MontySessionDisposed();
}

// ---------------------------------------------------------------------------
// Top-level helpers — pure utilities that do not need MontySession state.
// ---------------------------------------------------------------------------

/// Wraps [userCode] with restore preamble and persist postamble.
String _wrapSessionCode(String userCode, Map<String, Object?> state) {
  final restore = _generateSessionRestore(state);
  final persist = _generateSessionPersist(userCode, state);
  final (processedCode, hasResult) = code_capture.captureLastExpression(
    userCode,
  );

  final buf = StringBuffer(restore)
    ..write('\n')
    ..write(processedCode)
    ..write('\n')
    ..write(persist);

  if (hasResult) buf.write('\n__r');

  return buf.toString();
}

/// Generates Python code to restore [state] from `__restore_state__`.
String _generateSessionRestore(Map<String, Object?> state) {
  final buf = StringBuffer('__d = __restore_state__()');
  for (final key in state.keys) {
    buf.write('\n$key = __d["$key"]');
  }

  return buf.toString();
}

/// Generates Python code to persist [state] + new [userCode] targets.
String _generateSessionPersist(String userCode, Map<String, Object?> state) {
  final names = <String>{
    ...state.keys,
    ...code_capture.extractAssignmentTargets(userCode),
  };

  if (names.isEmpty) return '__persist_state__({})';

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

/// Drives the `run()` execution loop — handles all progress variants until
/// [MontyComplete], routing state restore/persist and OS calls transparently.
Future<MontyResult> _runSessionLoop(
  MontyPlatform platform,
  OsProvider? os,
  MontyProgress initialProgress,
  Map<String, Object?> Function() getState,
  void Function(List<MontyValue>) onPersist,
) async {
  var progress = initialProgress;
  while (true) {
    switch (progress) {
      case MontyPending(functionName: _restoreStateFn):
        progress = await _safeSessionResume(platform, getState());

      case MontyPending(functionName: _persistStateFn):
        onPersist(progress.arguments);
        progress = await _safeSessionResume(platform, null);

      case MontyComplete(:final result):
        return result;

      case MontyPending():
        progress = await _safeSessionResumeWithError(
          platform,
          'Unexpected external function in run() mode: '
          '${progress.functionName}',
        );

      case MontyResolveFutures():
        progress = await _safeSessionResume(platform, null);

      case MontyOsCall():
        final handler = os;
        if (handler != null) {
          progress = await _handleSessionOsCall(handler, progress, platform);
        } else {
          progress = await _safeSessionResumeWithError(
            platform,
            'OS operations not available — no OsProvider configured',
          );
        }
    }
  }
}

/// Resolves an OS call through [os], catching errors and returning a resume.
Future<MontyProgress> _handleSessionOsCall(
  OsProvider os,
  MontyOsCall osCall,
  MontyPlatform platform,
) async {
  try {
    final result = await os.resolve(osCall);
    return _safeSessionResume(platform, result);
  } on Object catch (e) {
    return _safeSessionResumeWithError(platform, e.toString());
  }
}

/// Wraps [MontyPlatform.start], converting platform errors to [MontyComplete].
Future<MontyProgress> _safeSessionStart(
  MontyPlatform platform,
  String code, {
  List<String>? externalFunctions,
  MontyLimits? limits,
  String? scriptName,
}) async {
  try {
    return await platform.start(
      code,
      externalFunctions: externalFunctions,
      limits: limits,
      scriptName: scriptName,
    );
  } on MontyScriptError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: e.exception,
        usage: _zeroUsage,
      ),
    );
  } on MontyError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: MontyException(message: e.message),
        usage: _zeroUsage,
      ),
    );
  }
}

/// Wraps [MontyPlatform.resume], converting platform errors to [MontyComplete].
Future<MontyProgress> _safeSessionResume(
  MontyPlatform platform,
  Object? returnValue,
) async {
  try {
    return await platform.resume(returnValue);
  } on MontyScriptError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: e.exception,
        usage: _zeroUsage,
      ),
    );
  } on MontyError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: MontyException(message: e.message),
        usage: _zeroUsage,
      ),
    );
  }
}

/// Wraps [MontyPlatform.resumeWithError], converting errors to [MontyComplete].
Future<MontyProgress> _safeSessionResumeWithError(
  MontyPlatform platform,
  String errorMessage,
) async {
  try {
    return await platform.resumeWithError(errorMessage);
  } on MontyScriptError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: e.exception,
        usage: _zeroUsage,
      ),
    );
  } on MontyError catch (e) {
    return MontyComplete(
      result: MontyResult(
        value: const MontyNull(),
        error: MontyException(message: e.message),
        usage: _zeroUsage,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MontySession
// ---------------------------------------------------------------------------

/// A stateful execution session that persists variables across calls.
///
/// Each [MontySession] wraps a [MontyPlatform] instance and maintains
/// a snapshot of Python globals between executions. Only JSON-serializable
/// types persist (int, float, str, bool, list, dict, None).
/// Non-serializable values are silently dropped after each call.
///
/// Subscribe to [persistedStateSignal] for reactive state updates, or read
/// [state] for a one-shot snapshot.
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
  ///
  /// If [os] is provided, OS calls (pathlib, os.getenv,
  /// datetime) are dispatched through it during [run]. Without a handler,
  /// OS calls resume with an error.
  MontySession({required MontyPlatform platform, OsProvider? os})
    : _platform = platform,
      _os = os {
    lifecycleSignal = _lifecycleSignal;
    persistedStateSignal = _persistedStateSignal;
  }

  final MontyPlatform _platform;
  final OsProvider? _os;
  Map<String, Object?> _state = {};

  final Signal<MontySessionLifecycle> _lifecycleSignal =
      signal(const MontySessionActive());
  final Signal<Map<String, Object?>> _persistedStateSignal =
      signal(const {});

  /// Reactive lifecycle state. Starts as [MontySessionActive], transitions
  /// to [MontySessionDisposed] when [dispose] is called.
  late final ReadonlySignal<MontySessionLifecycle> lifecycleSignal;

  /// Reactive persisted state map. Updates whenever Python persists new
  /// values via `__persist_state__` or [clearState] is called.
  ///
  /// Subscribe via `effect` to reactively forward Python session state:
  /// ```dart
  /// effect(() => syncState(session.persistedStateSignal.value));
  /// ```
  late final ReadonlySignal<Map<String, Object?>> persistedStateSignal;

  /// The current persisted state as a JSON-decoded map.
  ///
  /// Read-only snapshot. Returns an empty map if no state has been persisted.
  Map<String, Object?> get state => Map.from(_state);

  /// Executes [code] with state restored from previous calls.
  ///
  /// Returns the [MontyResult] from execution. Variables defined in
  /// [code] persist for subsequent calls (if JSON-serializable).
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    if (_lifecycleSignal.value is MontySessionDisposed) {
      throw StateError('MontySession has been disposed.');
    }
    final progress = await _safeSessionStart(
      _platform,
      _wrapSessionCode(code, _state),
      externalFunctions: [_restoreStateFn, _persistStateFn],
      limits: limits,
      scriptName: scriptName,
    );

    return _runSessionLoop(
      _platform, _os, progress,
      () => _state,
      _capturePersistArgs,
    );
  }

  /// Starts iterative execution of [code] with state restore/persist.
  ///
  /// Internal functions (`__restore_state__`, `__persist_state__`) are
  /// handled transparently — only user external functions are returned
  /// as [MontyPending] to the caller.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    if (_lifecycleSignal.value is MontySessionDisposed) {
      throw StateError('MontySession has been disposed.');
    }
    final allExtFns = [_restoreStateFn, _persistStateFn, ...?externalFunctions];
    final progress = await _safeSessionStart(
      _platform,
      _wrapSessionCode(code, _state),
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
    if (_lifecycleSignal.value is MontySessionDisposed) {
      throw StateError('MontySession has been disposed.');
    }

    return _interceptProgress(
      await _safeSessionResume(_platform, returnValue),
    );
  }

  /// Resumes a paused execution by raising an error with [errorMessage].
  ///
  /// Must be used instead of [MontyPlatform.resumeWithError] so that
  /// internal state functions are intercepted transparently.
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    if (_lifecycleSignal.value is MontySessionDisposed) {
      throw StateError('MontySession has been disposed.');
    }

    return _interceptProgress(
      await _safeSessionResumeWithError(_platform, errorMessage),
    );
  }

  /// Clears all persisted state.
  ///
  /// After calling this, the next `run()` or `start()` call begins with
  /// empty globals (as if creating a fresh session).
  void clearState() {
    if (_lifecycleSignal.value is MontySessionDisposed) {
      throw StateError('MontySession has been disposed.');
    }
    _state = {};
    _persistedStateSignal.value = const {};
  }

  /// Disposes the session.
  ///
  /// Clears persisted state and disposes the [OsProvider] if one was
  /// provided. Does NOT dispose the underlying [MontyPlatform].
  void dispose() {
    _state = {};
    _lifecycleSignal.value = const MontySessionDisposed();
    _persistedStateSignal.value = const {};
    unawaited(_os?.dispose());
  }

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _lifecycleSignal.value is MontySessionDisposed;

  /// Extracts simple assignment targets from [code].
  ///
  /// Returns variable names from top-level `identifier = expression`
  /// patterns. Excludes names starting with `_` (dunder/private).
  @visibleForTesting
  static Set<String> extractAssignmentTargets(String code) =>
      code_capture.extractAssignmentTargets(code);

  // ---------------------------------------------------------------------------
  // State interception
  // ---------------------------------------------------------------------------

  /// Intercepts internal state functions, passing through user progress.
  Future<MontyProgress> _interceptProgress(MontyProgress progress) async {
    var current = progress;
    while (true) {
      switch (current) {
        case MontyPending(functionName: _restoreStateFn):
          current = await _safeSessionResume(_platform, _state);

        case MontyPending(functionName: _persistStateFn):
          _capturePersistArgs(current.arguments);
          current = await _safeSessionResume(_platform, null);

        case MontyComplete():
        case MontyPending():
        case MontyOsCall():
        case MontyResolveFutures():
          return current;
      }
    }
  }

  /// Captures persisted state from `__persist_state__` arguments and
  /// updates [persistedStateSignal].
  void _capturePersistArgs(List<MontyValue> arguments) {
    if (arguments.isEmpty) return;
    final arg = arguments.first;
    if (arg is MontyDict) {
      _state = arg.entries.map((k, v) => MapEntry(k, v.dartValue));
      _persistedStateSignal.value = Map.from(_state);
    }
  }

}
