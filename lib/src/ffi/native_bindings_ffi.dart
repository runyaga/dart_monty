// coverage:ignore-file
// FFI glue; only testable via integration tests.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart' show MontyException;
import 'package:dart_monty/src/ffi/generated/dart_monty_bindings.dart'
    as ffi_native;
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:ffi/ffi.dart';

/// Real FFI implementation of [NativeBindings].
///
/// Uses `@Native` annotations via the generated bindings — symbol resolution
/// is handled automatically by the Dart native assets system.
class NativeBindingsFfi extends NativeBindings {
  /// Creates [NativeBindingsFfi].
  ///
  /// With native asset hooks, the library is resolved automatically by the
  /// Dart runtime. No manual path resolution is needed.
  NativeBindingsFfi();

  @override
  int create(String code, {String? externalFunctions, String? scriptName}) {
    final cCode = code.toNativeUtf8().cast<Char>();
    final nullChar = nullptr.cast<Char>();
    final cExtFns = externalFunctions != null
        ? externalFunctions.toNativeUtf8().cast<Char>()
        : nullChar;
    final cScriptName = scriptName != null
        ? scriptName.toNativeUtf8().cast<Char>()
        : nullChar;
    final outError = calloc<Pointer<Char>>();

    try {
      final handle = ffi_native.monty_create(
        cCode,
        cExtFns,
        cScriptName,
        outError,
      );
      if (handle == nullptr) {
        final errorMsg = _readAndFreeString(outError.value);
        throw MontyException(message: errorMsg ?? 'monty_create returned null');
      }

      return handle.address;
    } finally {
      calloc.free(cCode);
      if (externalFunctions != null) calloc.free(cExtFns);
      if (scriptName != null) calloc.free(cScriptName);
      calloc.free(outError);
    }
  }

  @override
  void free(int handle) {
    if (handle == 0) return;
    ffi_native.monty_free(Pointer<ffi_native.MontyHandle>.fromAddress(handle));
  }

  @override
  RunResult run(int handle) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final outResult = calloc<Pointer<Char>>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_run(ptr, outResult, outError);
      final resultJson = _readAndFreeString(outResult.value);
      final errorMsg = _readAndFreeString(outError.value);

      return RunResult(
        tag: tag.value,
        resultJson: resultJson,
        errorMessage: errorMsg,
      );
    } finally {
      calloc
        ..free(outResult)
        ..free(outError);
    }
  }

  @override
  ProgressResult start(int handle) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_start(ptr, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc.free(outError);
    }
  }

  @override
  ProgressResult resume(int handle, String valueJson) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final cValue = valueJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_resume(ptr, cValue, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cValue)
        ..free(outError);
    }
  }

  @override
  ProgressResult resumeWithError(int handle, String errorMessage) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final cError = errorMessage.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_resume_with_error(ptr, cError, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cError)
        ..free(outError);
    }
  }

  @override
  ProgressResult resumeAsFuture(int handle) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_resume_as_future(ptr, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc.free(outError);
    }
  }

  @override
  ProgressResult resolveFutures(
    int handle,
    String resultsJson,
    String errorsJson,
  ) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final cResults = resultsJson.toNativeUtf8().cast<Char>();
    final cErrors = errorsJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_resume_futures(
        ptr,
        cResults,
        cErrors,
        outError,
      );

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cResults)
        ..free(cErrors)
        ..free(outError);
    }
  }

  @override
  void setMemoryLimit(int handle, int bytes) {
    ffi_native.monty_set_memory_limit(
      Pointer<ffi_native.MontyHandle>.fromAddress(handle),
      bytes,
    );
  }

  @override
  void setTimeLimitMs(int handle, int ms) {
    ffi_native.monty_set_time_limit_ms(
      Pointer<ffi_native.MontyHandle>.fromAddress(handle),
      ms,
    );
  }

  @override
  void setStackLimit(int handle, int depth) {
    ffi_native.monty_set_stack_limit(
      Pointer<ffi_native.MontyHandle>.fromAddress(handle),
      depth,
    );
  }

  @override
  Uint8List snapshot(int handle) {
    final ptr = Pointer<ffi_native.MontyHandle>.fromAddress(handle);
    final outLen = calloc<Size>();

    try {
      final buf = ffi_native.monty_snapshot(ptr, outLen);
      if (buf == nullptr) {
        throw StateError('monty_snapshot returned null');
      }
      final len = outLen.value;
      final bytes = Uint8List.fromList(buf.cast<Uint8>().asTypedList(len));
      ffi_native.monty_bytes_free(buf, len);

      return bytes;
    } finally {
      calloc.free(outLen);
    }
  }

  @override
  int restore(Uint8List data) {
    final cData = calloc<Uint8>(data.length);
    final outError = calloc<Pointer<Char>>();

    try {
      cData.asTypedList(data.length).setAll(0, data);
      final handle = ffi_native.monty_restore(cData, data.length, outError);
      if (handle == nullptr) {
        final errorMsg = _readAndFreeString(outError.value);
        throw MontyException(
          message: errorMsg ?? 'monty_restore returned null',
        );
      }

      return handle.address;
    } finally {
      calloc
        ..free(cData)
        ..free(outError);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  ProgressResult _buildProgressResult(
    Pointer<ffi_native.MontyHandle> ptr,
    ffi_native.MontyProgressTag tag,
    Pointer<Char> errorPtr,
  ) {
    switch (tag) {
      case ffi_native.MontyProgressTag.MONTY_PROGRESS_COMPLETE:
        final resultJsonPtr = ffi_native.monty_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);
        final isError = ffi_native.monty_complete_is_error(ptr);

        return ProgressResult(tag: 0, resultJson: resultJson, isError: isError);

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_PENDING:
        final fnNamePtr = ffi_native.monty_pending_fn_name(ptr);
        final fnName = _readAndFreeString(fnNamePtr);
        final argsPtr = ffi_native.monty_pending_fn_args_json(ptr);
        final argsJson = _readAndFreeString(argsPtr);
        final kwargsPtr = ffi_native.monty_pending_fn_kwargs_json(ptr);
        final kwargsJson = _readAndFreeString(kwargsPtr);
        final callId = ffi_native.monty_pending_call_id(ptr);
        final methodCall = ffi_native.monty_pending_method_call(ptr);

        return ProgressResult(
          tag: 1,
          functionName: fnName,
          argumentsJson: argsJson,
          kwargsJson: kwargsJson,
          callId: callId,
          methodCall: methodCall == 1,
        );

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_ERROR:
        final errorMsg = _readAndFreeString(errorPtr);
        // handle_exception sets state to Complete with full error JSON
        final resultJsonPtr = ffi_native.monty_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);

        return ProgressResult(
          tag: 2,
          errorMessage: errorMsg,
          resultJson: resultJson,
        );

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_RESOLVE_FUTURES:
        final callIdsPtr = ffi_native.monty_pending_future_call_ids(ptr);
        final callIdsJson = _readAndFreeString(callIdsPtr);

        return ProgressResult(tag: 3, futureCallIdsJson: callIdsJson);

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_OS_CALL:
        final fnNamePtr = ffi_native.monty_os_call_fn_name(ptr);
        final fnName = _readAndFreeString(fnNamePtr);
        final argsPtr = ffi_native.monty_os_call_args_json(ptr);
        final argsJson = _readAndFreeString(argsPtr);
        final kwargsPtr = ffi_native.monty_os_call_kwargs_json(ptr);
        final kwargsJson = _readAndFreeString(kwargsPtr);
        final callId = ffi_native.monty_os_call_id(ptr);

        return ProgressResult(
          tag: 4,
          functionName: fnName,
          argumentsJson: argsJson,
          kwargsJson: kwargsJson,
          callId: callId,
        );
    }
  }

  /// Reads a C string, converts to Dart string, and frees via
  /// `monty_string_free`. Returns `null` if the pointer is null.
  String? _readAndFreeString(Pointer<Char> ptr) {
    if (ptr == nullptr) return null;
    final str = ptr.cast<Utf8>().toDartString();
    ffi_native.monty_string_free(ptr);

    return str;
  }
}
