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
  // Translation (same logic as FfiCoreBindings._translateRunResult)
  // -----------------------------------------------------------------------

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
