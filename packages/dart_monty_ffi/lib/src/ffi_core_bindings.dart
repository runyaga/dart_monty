import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_ffi/src/native_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Adapts [NativeBindings] (sync, int handles, [RunResult]/[ProgressResult])
/// to the [MontyCoreBindings] interface (async, [CoreRunResult]/
/// [CoreProgressResult]).
///
/// Owns the handle lifecycle internally — callers never see the raw `int`
/// handle. Translation methods extract JSON from the FFI result structs
/// and map them to the core intermediate types that [BaseMontyPlatform]
/// consumes.
///
/// ```dart
/// final bindings = FfiCoreBindings(bindings: NativeBindingsFfi());
/// final monty = MontyFfi(bindings: bindings);
/// ```
class FfiCoreBindings implements MontyCoreBindings {
  /// Creates an [FfiCoreBindings] backed by [bindings].
  FfiCoreBindings({required NativeBindings bindings}) : _bindings = bindings;

  final NativeBindings _bindings;
  int? _handle;

  @override
  Future<bool> init() async => true;

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    final handle = _bindings.create(code, scriptName: scriptName);
    try {
      _applyLimits(handle, limitsJson);
      final result = _bindings.run(handle);

      return _translateRunResult(result);
    } finally {
      _bindings.free(handle);
    }
  }

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    final extFns = _parseExtFns(extFnsJson);
    final handle = _bindings.create(
      code,
      externalFunctions: extFns,
      scriptName: scriptName,
    );
    _applyLimits(handle, limitsJson);
    final progress = _bindings.start(handle);

    return _translateProgressResult(handle, progress);
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    final handle = _requireHandle('resume');
    final progress = _bindings.resume(handle, valueJson);

    return _translateProgressResult(handle, progress);
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    final handle = _requireHandle('resumeWithError');
    final progress = _bindings.resumeWithError(handle, errorMessage);

    return _translateProgressResult(handle, progress);
  }

  @override
  Future<CoreProgressResult> resumeAsFuture() async {
    final handle = _requireHandle('resumeAsFuture');
    final progress = _bindings.resumeAsFuture(handle);

    return _translateProgressResult(handle, progress);
  }

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    final handle = _requireHandle('resolveFutures');
    final progress = _bindings.resolveFutures(handle, resultsJson, errorsJson);

    return _translateProgressResult(handle, progress);
  }

  @override
  Future<Uint8List> snapshot() async {
    final handle = _requireHandle('snapshot');

    return _bindings.snapshot(handle);
  }

  @override
  Future<void> restoreSnapshot(Uint8List data) async {
    _handle = _bindings.restore(data);
  }

  @override
  Future<void> dispose() async {
    final handle = _handle;
    if (handle != null) {
      _bindings.free(handle);
      _handle = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Translation helpers
  // ---------------------------------------------------------------------------

  CoreRunResult _translateRunResult(RunResult result) {
    if (result.tag == 0) {
      final resultJson = result.resultJson;
      if (resultJson == null) {
        throw StateError('OK result JSON is null');
      }
      final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
      final usageMap = jsonMap['usage'] as Map<String, dynamic>?;
      final errorMap = jsonMap['error'] as Map<String, dynamic>?;

      return CoreRunResult(
        ok: true,
        value: jsonMap['value'] as Object?,
        usage: usageMap != null ? MontyResourceUsage.fromJson(usageMap) : null,
        printOutput: jsonMap['print_output'] as String?,
        error: errorMap?['message'] as String?,
        excType: errorMap?['exc_type'] as String?,
        traceback: errorMap?['traceback'] as List<Object?>?,
      );
    }

    // tag == 1: error
    final resultJson = result.resultJson;
    if (resultJson != null) {
      final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
      final errorMap = jsonMap['error'] as Map<String, dynamic>?;
      if (errorMap != null) {
        return CoreRunResult(
          ok: false,
          error: errorMap['message'] as String?,
          excType: errorMap['exc_type'] as String?,
          traceback: errorMap['traceback'] as List<Object?>?,
          filename: errorMap['filename'] as String?,
          lineNumber: errorMap['line_number'] as int?,
          columnNumber: errorMap['column_number'] as int?,
          sourceCode: errorMap['source_code'] as String?,
        );
      }
    }

    return CoreRunResult(
      ok: false,
      error: result.errorMessage ?? 'Unknown error',
    );
  }

  CoreProgressResult _translateProgressResult(
    int handle,
    ProgressResult progress,
  ) {
    switch (progress.tag) {
      case 0: // complete
        _freeHandle(handle);
        final resultJson = progress.resultJson;
        if (resultJson == null) {
          throw StateError('Complete result JSON is null');
        }
        final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
        final usageMap = jsonMap['usage'] as Map<String, dynamic>?;
        final errorMap = jsonMap['error'] as Map<String, dynamic>?;

        return CoreProgressResult(
          state: 'complete',
          value: jsonMap['value'] as Object?,
          usage:
              usageMap != null ? MontyResourceUsage.fromJson(usageMap) : null,
          error: errorMap?['message'] as String?,
          excType: errorMap?['exc_type'] as String?,
          traceback: errorMap?['traceback'] as List<Object?>?,
        );

      case 1: // pending
        _handle = handle;
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

        return CoreProgressResult(
          state: 'pending',
          functionName: progress.functionName ?? '',
          arguments: args,
          kwargs: kwargs,
          callId: progress.callId ?? 0,
          methodCall: progress.methodCall ?? false,
        );

      case 2: // error
        _freeHandle(handle);
        final errorResultJson = progress.resultJson;
        if (errorResultJson != null) {
          final jsonMap = json.decode(errorResultJson) as Map<String, dynamic>;
          final errorMap = jsonMap['error'] as Map<String, dynamic>?;
          if (errorMap != null) {
            return CoreProgressResult(
              state: 'error',
              error: errorMap['message'] as String?,
              excType: errorMap['exc_type'] as String?,
              traceback: errorMap['traceback'] as List<Object?>?,
              filename: errorMap['filename'] as String?,
              lineNumber: errorMap['line_number'] as int?,
              columnNumber: errorMap['column_number'] as int?,
              sourceCode: errorMap['source_code'] as String?,
            );
          }
        }

        return CoreProgressResult(
          state: 'error',
          error: progress.errorMessage ?? 'Unknown error',
        );

      case 3: // resolve_futures
        _handle = handle;
        final idsJson = progress.futureCallIdsJson;
        if (idsJson == null) {
          throw StateError('Future call IDs JSON is null');
        }
        final ids = List<int>.from(
          json.decode(idsJson) as List<Object?>,
        );

        return CoreProgressResult(
          state: 'resolve_futures',
          pendingCallIds: ids,
        );

      default:
        _freeHandle(handle);
        throw StateError('Unknown progress tag: ${progress.tag}');
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  int _requireHandle(String method) {
    final handle = _handle;
    if (handle == null) {
      throw StateError('Cannot $method: no active handle');
    }

    return handle;
  }

  void _freeHandle(int handle) {
    if (_handle == handle) {
      _handle = null;
    }
    _bindings.free(handle);
  }

  void _applyLimits(int handle, String? limitsJson) {
    if (limitsJson == null) return;
    final limits = json.decode(limitsJson) as Map<String, dynamic>;
    if (limits['memory_bytes'] case final int bytes) {
      _bindings.setMemoryLimit(handle, bytes);
    }
    if (limits['timeout_ms'] case final int ms) {
      _bindings.setTimeLimitMs(handle, ms);
    }
    if (limits['stack_depth'] case final int depth) {
      _bindings.setStackLimit(handle, depth);
    }
  }

  /// Converts a JSON array of function names to the comma-separated format
  /// expected by [NativeBindings.create].
  String? _parseExtFns(String? extFnsJson) {
    if (extFnsJson == null) return null;
    final list = List<String>.from(
      json.decode(extFnsJson) as List<Object?>,
    );

    return list.isNotEmpty ? list.join(',') : null;
  }
}
