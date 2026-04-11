// coverage:ignore-file
// FFI glue; only testable via integration tests.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_monty/src/ffi/generated/dart_monty_bindings.dart'
    as ffi_native;
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/platform/monty_error.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
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
        final errorMsg =
            _readAndFreeString(outError.value) ?? 'monty_create returned null';
        // Parse errors (SyntaxError, etc.) are script errors — throw
        // MontyScriptError so callers using `on MontyScriptError` catch them.
        final excType = _extractExcType(errorMsg);
        final exception = MontyException(message: errorMsg, excType: excType);
        throw MontyScriptError(
          errorMsg,
          excType: excType,
          exception: exception,
        );
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
    ffi_native.monty_free(Pointer.fromAddress(handle));
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
    ffi_native.monty_set_memory_limit(Pointer.fromAddress(handle), bytes);
  }

  @override
  void setTimeLimitMs(int handle, int ms) {
    ffi_native.monty_set_time_limit_ms(Pointer.fromAddress(handle), ms);
  }

  @override
  void setStackLimit(int handle, int depth) {
    ffi_native.monty_set_stack_limit(Pointer.fromAddress(handle), depth);
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
  // REPL
  // ---------------------------------------------------------------------------

  @override
  int replCreate({String? scriptName}) {
    final cScriptName = scriptName != null
        ? scriptName.toNativeUtf8().cast<Char>()
        : nullptr.cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final handle = ffi_native.monty_repl_create(cScriptName, outError);
      if (handle == nullptr) {
        final errorMsg =
            _readAndFreeString(outError.value) ?? 'monty_repl_create failed';
        throw StateError(errorMsg);
      }

      return handle.address;
    } finally {
      if (scriptName != null) calloc.free(cScriptName);
      calloc.free(outError);
    }
  }

  @override
  void replFree(int handle) {
    if (handle == 0) return;
    ffi_native.monty_repl_free(Pointer.fromAddress(handle));
  }

  @override
  RunResult replFeedRun(int handle, String code) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cCode = code.toNativeUtf8().cast<Char>();
    final outResult = calloc<Pointer<Char>>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_feed_run(
        ptr,
        cCode,
        outResult,
        outError,
      );
      final resultJson = _readAndFreeString(outResult.value);
      final errorMsg = _readAndFreeString(outError.value);

      return RunResult(
        tag: tag.value,
        resultJson: resultJson,
        errorMessage: errorMsg,
      );
    } finally {
      calloc
        ..free(cCode)
        ..free(outResult)
        ..free(outError);
    }
  }

  @override
  int replDetectContinuation(String source) {
    final cSource = source.toNativeUtf8().cast<Char>();
    try {
      return ffi_native.monty_repl_detect_continuation(cSource);
    } finally {
      calloc.free(cSource);
    }
  }

  // ---------------------------------------------------------------------------
  // REPL iterative execution
  // ---------------------------------------------------------------------------

  @override
  void replSetExtFns(int handle, String extFns) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cExtFns = extFns.toNativeUtf8().cast<Char>();
    try {
      ffi_native.monty_repl_set_ext_fns(ptr, cExtFns);
    } finally {
      calloc.free(cExtFns);
    }
  }

  @override
  ProgressResult replFeedStart(int handle, String code) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cCode = code.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_feed_start(ptr, cCode, outError);

      return _buildReplProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cCode)
        ..free(outError);
    }
  }

  @override
  ProgressResult replResume(int handle, String valueJson) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cValue = valueJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_resume(ptr, cValue, outError);

      return _buildReplProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cValue)
        ..free(outError);
    }
  }

  @override
  ProgressResult replResumeWithError(int handle, String errorMessage) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cError = errorMessage.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_resume_with_error(
        ptr,
        cError,
        outError,
      );

      return _buildReplProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cError)
        ..free(outError);
    }
  }

  @override
  ProgressResult replResumeAsFuture(int handle) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_resume_as_future(ptr, outError);

      return _buildReplProgressResult(ptr, tag, outError.value);
    } finally {
      calloc.free(outError);
    }
  }

  @override
  ProgressResult replResolveFutures(
    int handle,
    String resultsJson,
    String errorsJson,
  ) {
    final ptr = Pointer<ffi_native.MontyReplHandle>.fromAddress(handle);
    final cResults = resultsJson.toNativeUtf8().cast<Char>();
    final cErrors = errorsJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = ffi_native.monty_repl_resume_futures(
        ptr,
        cResults,
        cErrors,
        outError,
      );

      return _buildReplProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cResults)
        ..free(cErrors)
        ..free(outError);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Builds a [ProgressResult] from REPL handle state accessors.
  ProgressResult _buildReplProgressResult(
    Pointer<ffi_native.MontyReplHandle> ptr,
    ffi_native.MontyProgressTag tag,
    Pointer<Char> errorPtr,
  ) {
    switch (tag) {
      case ffi_native.MontyProgressTag.MONTY_PROGRESS_COMPLETE:
        final resultJsonPtr = ffi_native.monty_repl_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);
        final isError = ffi_native.monty_repl_complete_is_error(ptr);

        return ProgressResult(tag: 0, resultJson: resultJson, isError: isError);

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_PENDING:
        final fnNamePtr = ffi_native.monty_repl_pending_fn_name(ptr);
        final fnName = _readAndFreeString(fnNamePtr);
        final argsPtr = ffi_native.monty_repl_pending_fn_args_json(ptr);
        final argsJson = _readAndFreeString(argsPtr);
        final kwargsPtr = ffi_native.monty_repl_pending_fn_kwargs_json(ptr);
        final kwargsJson = _readAndFreeString(kwargsPtr);
        final callId = ffi_native.monty_repl_pending_call_id(ptr);
        final methodCall = ffi_native.monty_repl_pending_method_call(ptr);

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
        final resultJsonPtr = ffi_native.monty_repl_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);

        return ProgressResult(
          tag: 2,
          errorMessage: errorMsg,
          resultJson: resultJson,
        );

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_RESOLVE_FUTURES:
        final callIdsPtr = ffi_native.monty_repl_pending_future_call_ids(ptr);
        final callIdsJson = _readAndFreeString(callIdsPtr);

        return ProgressResult(tag: 3, futureCallIdsJson: callIdsJson);

      case ffi_native.MontyProgressTag.MONTY_PROGRESS_OS_CALL:
        final fnNamePtr = ffi_native.monty_repl_os_call_fn_name(ptr);
        final fnName = _readAndFreeString(fnNamePtr);
        final argsPtr = ffi_native.monty_repl_os_call_args_json(ptr);
        final argsJson = _readAndFreeString(argsPtr);
        final kwargsPtr = ffi_native.monty_repl_os_call_kwargs_json(ptr);
        final kwargsJson = _readAndFreeString(kwargsPtr);
        final callId = ffi_native.monty_repl_os_call_id(ptr);

        return ProgressResult(
          tag: 4,
          functionName: fnName,
          argumentsJson: argsJson,
          kwargsJson: kwargsJson,
          callId: callId,
        );
    }
  }

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

  /// Extracts the Python exception type from a "Type: message" error string.
  ///
  /// Returns `null` if no colon-separated prefix is found.
  static String? _extractExcType(String message) {
    final colonIdx = message.indexOf(':');
    if (colonIdx <= 0) return null;
    final prefix = message.substring(0, colonIdx);
    // Only treat it as an exc type if it looks like a Python identifier
    // (e.g. "SyntaxError", "ValueError").
    if (RegExp(
      r'^[A-Z][a-zA-Z]*(?:Error|Exception|Warning)$',
    ).hasMatch(prefix)) {
      return prefix;
    }

    return null;
  }
}
