import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_ffi/src/native_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Interpreter lifecycle state.
enum _State { idle, active, disposed }

/// Native FFI implementation of [MontyPlatform].
///
/// Uses a [NativeBindings] abstraction to call into the Rust C API.
/// Manages a state machine: idle -> active -> disposed.
///
/// ```dart
/// final monty = MontyFfi(bindings: NativeBindingsFfi());
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyFfi extends MontyPlatform {
  /// Creates a [MontyFfi] with the given [bindings].
  MontyFfi({required NativeBindings bindings}) : _bindings = bindings;

  /// Creates a [MontyFfi] that already owns [handle] in idle state.
  ///
  /// Used internally by [restore] to wrap a restored handle.
  MontyFfi._withHandle({
    required NativeBindings bindings,
    required int handle,
  })  : _bindings = bindings,
        _handle = handle;

  final NativeBindings _bindings;
  _State _state = _State.idle;
  int? _handle;

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    _assertNotDisposed('run');
    _assertIdle('run');
    _rejectInputs(inputs);

    final handle = _bindings.create(
      code,
      scriptName: scriptName,
    );
    try {
      _applyLimits(handle, limits);
      final result = _bindings.run(handle);

      return _decodeRunResult(result);
    } finally {
      _bindings.free(handle);
    }
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    _assertNotDisposed('start');
    _assertIdle('start');
    _rejectInputs(inputs);

    final extFns = externalFunctions != null && externalFunctions.isNotEmpty
        ? externalFunctions.join(',')
        : null;

    final handle = _bindings.create(
      code,
      externalFunctions: extFns,
      scriptName: scriptName,
    );
    _applyLimits(handle, limits);

    final progress = _bindings.start(handle);

    return _handleProgress(handle, progress);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    _assertNotDisposed('resume');
    _assertActive('resume');
    final handle = _handle;
    if (handle == null) {
      throw StateError('Cannot resume: no active handle');
    }

    final valueJson = json.encode(returnValue);
    final progress = _bindings.resume(handle, valueJson);

    return _handleProgress(handle, progress);
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _assertNotDisposed('resumeWithError');
    _assertActive('resumeWithError');
    final handle = _handle;
    if (handle == null) {
      throw StateError('Cannot resumeWithError: no active handle');
    }

    final progress = _bindings.resumeWithError(handle, errorMessage);

    return _handleProgress(handle, progress);
  }

  @override
  Future<Uint8List> snapshot() async {
    _assertNotDisposed('snapshot');
    _assertActive('snapshot');
    final handle = _handle;
    if (handle == null) {
      throw StateError('Cannot snapshot: no active handle');
    }

    return _bindings.snapshot(handle);
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    _assertNotDisposed('restore');
    _assertIdle('restore');

    final handle = _bindings.restore(data);

    return MontyFfi._withHandle(bindings: _bindings, handle: handle);
  }

  @override
  Future<void> dispose() async {
    if (_state == _State.disposed) return;

    final handle = _handle;
    if (handle != null) {
      _bindings.free(handle);
      _handle = null;
    }
    _state = _State.disposed;
  }

  // ---------------------------------------------------------------------------
  // Progress handling
  // ---------------------------------------------------------------------------

  MontyProgress _handleProgress(int handle, ProgressResult progress) {
    switch (progress.tag) {
      case 0: // MONTY_PROGRESS_COMPLETE
        final resultJson = progress.resultJson;
        if (resultJson == null) {
          throw StateError('Complete result JSON is null');
        }
        final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
        _freeHandle(handle);

        return MontyComplete(result: MontyResult.fromJson(jsonMap));

      case 1: // MONTY_PROGRESS_PENDING
        _handle = handle;
        _state = _State.active;
        final fnName = progress.functionName;
        if (fnName == null) {
          throw StateError('Pending function name is null');
        }
        final argsJson = progress.argumentsJson;
        final args = argsJson != null
            ? List<Object?>.from(
                json.decode(argsJson) as List<Object?>,
              )
            : const <Object?>[];

        final kwargsJson = progress.kwargsJson;
        Map<String, Object?>? kwargs;
        if (kwargsJson != null) {
          final decoded = Map<String, Object?>.from(
            json.decode(kwargsJson) as Map<String, dynamic>,
          );
          kwargs = decoded.isNotEmpty ? decoded : null;
        }

        return MontyPending(
          functionName: fnName,
          arguments: args,
          kwargs: kwargs,
          callId: progress.callId ?? 0,
          methodCall: progress.methodCall ?? false,
        );

      case 2: // MONTY_PROGRESS_ERROR
        _freeHandle(handle);
        // Parse full result JSON for exc_type, traceback, etc.
        final errorResultJson = progress.resultJson;
        if (errorResultJson != null) {
          final jsonMap = json.decode(errorResultJson) as Map<String, dynamic>;
          final errorMap = jsonMap['error'] as Map<String, dynamic>?;
          if (errorMap != null) {
            throw MontyException.fromJson(errorMap);
          }
        }
        throw MontyException(message: progress.errorMessage ?? 'Unknown error');

      default:
        _freeHandle(handle);
        throw StateError('Unknown progress tag: ${progress.tag}');
    }
  }

  // ---------------------------------------------------------------------------
  // Run result decoding
  // ---------------------------------------------------------------------------

  MontyResult _decodeRunResult(RunResult result) {
    if (result.tag == 0) {
      // MONTY_RESULT_OK
      final resultJson = result.resultJson;
      if (resultJson == null) {
        throw StateError('OK result JSON is null');
      }
      final jsonMap = json.decode(resultJson) as Map<String, dynamic>;

      return MontyResult.fromJson(jsonMap);
    }
    // MONTY_RESULT_ERROR — parse full result JSON for exc_type, traceback, etc.
    final resultJson = result.resultJson;
    if (resultJson != null) {
      final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
      final errorMap = jsonMap['error'] as Map<String, dynamic>?;
      if (errorMap != null) {
        throw MontyException.fromJson(errorMap);
      }
    }
    throw MontyException(message: result.errorMessage ?? 'Unknown error');
  }

  // ---------------------------------------------------------------------------
  // State assertions
  // ---------------------------------------------------------------------------

  void _assertNotDisposed(String method) {
    if (_state == _State.disposed) {
      throw StateError('Cannot call $method() on a disposed MontyFfi');
    }
  }

  void _assertIdle(String method) {
    if (_state == _State.active) {
      throw StateError(
        'Cannot call $method() while execution is active. '
        'Call resume(), resumeWithError(), or dispose() first.',
      );
    }
  }

  void _assertActive(String method) {
    if (_state != _State.active) {
      throw StateError(
        'Cannot call $method() when not in active state. '
        'Call start() first.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _rejectInputs(Map<String, Object?>? inputs) {
    if (inputs != null && inputs.isNotEmpty) {
      throw UnsupportedError(
        'The native FFI backend does not support the inputs parameter. '
        'Use externalFunctions with start()/resume() instead.',
      );
    }
  }

  void _applyLimits(int handle, MontyLimits? limits) {
    if (limits == null) return;
    if (limits.memoryBytes case final bytes?) {
      _bindings.setMemoryLimit(handle, bytes);
    }
    if (limits.timeoutMs case final ms?) {
      _bindings.setTimeLimitMs(handle, ms);
    }
    if (limits.stackDepth case final depth?) {
      _bindings.setStackLimit(handle, depth);
    }
  }

  void _freeHandle(int handle) {
    if (_handle == handle) {
      _handle = null;
    }
    _bindings.free(handle);
    if (_state == _State.active) {
      _state = _State.idle;
    }
  }
}
