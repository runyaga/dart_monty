import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:dart_monty/src/ffi/generated/dart_monty_bindings.dart'
    as ffi_native;
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/platform/core_bindings.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/repl/repl_bindings.dart';

/// GC safety net for Rust MontyReplHandle pointers.
final class _ReplHandleGuard implements ffi.Finalizable {
  const _ReplHandleGuard(this.address);
  final int address;
}

/// NativeFinalizer backed by the C `monty_repl_free` function.
final _replHandleFinalizer = ffi.NativeFinalizer(
  ffi.Native.addressOf<
        ffi.NativeFunction<
          ffi.Void Function(ffi.Pointer<ffi_native.MontyReplHandle>)
        >
      >(ffi_native.monty_repl_free)
      .cast(),
);

/// FFI implementation of [ReplBindings].
///
/// Manages a persistent REPL handle with GC-safe cleanup via
/// [ffi.NativeFinalizer].
class FfiReplBindings implements ReplBindings {
  /// Creates [FfiReplBindings] backed by [bindings].
  FfiReplBindings({required NativeBindings bindings}) : _bindings = bindings;

  final NativeBindings _bindings;
  int? _replHandle;
  _ReplHandleGuard? _guard;
  Object? _detachToken;

  @override
  Future<void> create({String? scriptName}) async {
    if (_replHandle != null) {
      await dispose();
    }
    final handle = _bindings.replCreate(scriptName: scriptName);
    _replHandle = handle;

    // Attach GC finalizer as safety net.
    final guard = _ReplHandleGuard(handle);
    final token = Object();
    _replHandleFinalizer.attach(
      guard,
      ffi.Pointer.fromAddress(handle),
      detach: token,
    );
    _guard = guard;
    _detachToken = token;
  }

  @override
  Future<CoreRunResult> feedRun(String code) async {
    final handle = _replHandle;
    if (handle == null) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = _bindings.replFeedRun(handle, code);

    return _translateRunResult(result);
  }

  @override
  Future<int> detectContinuation(String source) async {
    return _bindings.replDetectContinuation(source);
  }

  @override
  Future<void> dispose() async {
    final handle = _replHandle;
    if (handle == null) return;

    // Detach finalizer before explicit free.
    if (_guard != null && _detachToken != null) {
      _replHandleFinalizer.detach(_detachToken!);
    }
    _bindings.replFree(handle);
    _replHandle = null;
    _guard = null;
    _detachToken = null;
  }

  // -----------------------------------------------------------------------
  // Phase 2: iterative execution
  // -----------------------------------------------------------------------

  @override
  void setExtFns(List<String> names) {
    final handle = _replHandle;
    if (handle == null) return;
    _bindings.replSetExtFns(handle, names.join(','));
  }

  @override
  Future<CoreProgressResult> feedStart(String code) async {
    final handle = _replHandle;
    if (handle == null) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = _bindings.replFeedStart(handle, code);

    return _translateProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    final handle = _replHandle;
    if (handle == null) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = _bindings.replResume(handle, valueJson);

    return _translateProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    final handle = _replHandle;
    if (handle == null) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = _bindings.replResumeWithError(handle, errorMessage);

    return _translateProgressResult(result);
  }

  // -----------------------------------------------------------------------
  // Translation (same logic as FfiCoreBindings._translateRunResult)
  // -----------------------------------------------------------------------

  CoreProgressResult _translateProgressResult(ProgressResult progress) {
    switch (progress.tag) {
      case 0: // COMPLETE
        return _translateComplete(progress);
      case 1: // PENDING
        return _translatePending(progress);
      case 2: // ERROR
        return _translateError(progress);
      case 3: // RESOLVE_FUTURES
        List<int>? callIds;
        if (progress.futureCallIdsJson != null) {
          callIds = (json.decode(progress.futureCallIdsJson!) as List)
              .cast<int>();
        }
        return CoreProgressResult(
          state: 'resolve_futures',
          pendingCallIds: callIds,
        );
      case 4: // OS_CALL
        List<Object?>? parsedArgs;
        if (progress.argumentsJson != null) {
          parsedArgs = (json.decode(progress.argumentsJson!) as List)
              .cast<Object?>();
        }
        Map<String, Object?>? parsedKwargs;
        if (progress.kwargsJson != null) {
          parsedKwargs =
              (json.decode(progress.kwargsJson!) as Map<String, dynamic>)
                  .cast<String, Object?>();
        }
        return CoreProgressResult(
          state: 'os_call',
          functionName: progress.functionName,
          arguments: parsedArgs,
          kwargs: parsedKwargs,
          callId: progress.callId,
        );
      default:
        return CoreProgressResult(
          state: 'error',
          error: 'Unknown progress tag: ${progress.tag}',
        );
    }
  }

  CoreProgressResult _translateComplete(ProgressResult progress) {
    final resultJson = progress.resultJson;
    if (resultJson == null) {
      return const CoreProgressResult(state: 'complete');
    }
    final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
    final usageMap = jsonMap['usage'] as Map<String, dynamic>?;
    final errorMap = jsonMap['error'] as Map<String, dynamic>?;

    return CoreProgressResult(
      state: 'complete',
      value: jsonMap['value'] as Object?,
      usage: usageMap != null ? MontyResourceUsage.fromJson(usageMap) : null,
      printOutput: jsonMap['print_output'] as String?,
      error: errorMap?['message'] as String?,
      excType: errorMap?['exc_type'] as String?,
      traceback: errorMap?['traceback'] as List<Object?>?,
    );
  }

  CoreProgressResult _translatePending(ProgressResult progress) {
    List<Object?>? parsedArgs;
    if (progress.argumentsJson != null) {
      parsedArgs = (json.decode(progress.argumentsJson!) as List)
          .cast<Object?>();
    }
    Map<String, Object?>? parsedKwargs;
    if (progress.kwargsJson != null) {
      parsedKwargs = (json.decode(progress.kwargsJson!) as Map<String, dynamic>)
          .cast<String, Object?>();
    }

    return CoreProgressResult(
      state: 'pending',
      functionName: progress.functionName,
      arguments: parsedArgs,
      kwargs: parsedKwargs,
      callId: progress.callId,
      methodCall: progress.methodCall,
    );
  }

  CoreProgressResult _translateError(ProgressResult progress) {
    final resultJson = progress.resultJson;
    if (resultJson != null) {
      final jsonMap = json.decode(resultJson) as Map<String, dynamic>;
      final errorMap = jsonMap['error'] as Map<String, dynamic>?;
      if (errorMap != null) {
        return CoreProgressResult(
          state: 'error',
          error: errorMap['message'] as String?,
          excType: errorMap['exc_type'] as String?,
          traceback: errorMap['traceback'] as List<Object?>?,
        );
      }
    }

    return CoreProgressResult(
      state: 'error',
      error: progress.errorMessage ?? 'Unknown error',
    );
  }

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
}
