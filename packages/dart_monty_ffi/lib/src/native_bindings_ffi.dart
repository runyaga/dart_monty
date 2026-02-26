import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dart_monty_ffi/src/generated/dart_monty_bindings.dart';
import 'package:dart_monty_ffi/src/native_bindings.dart';
import 'package:dart_monty_ffi/src/native_library_loader.dart';
import 'package:ffi/ffi.dart';

/// Real FFI implementation of [NativeBindings].
///
/// Manages all pointer lifecycle internally: allocates out-params, reads
/// C strings, and calls `monty_string_free`/`monty_bytes_free`.
class NativeBindingsFfi extends NativeBindings {
  /// Creates [NativeBindingsFfi] by opening the native library.
  ///
  /// Pass [libraryPath] to override the default platform resolution.
  /// On iOS, symbols are statically linked into the main executable, so
  /// [DynamicLibrary.process] is used instead of [DynamicLibrary.open].
  NativeBindingsFfi({String? libraryPath})
      : _lib = DartMontyBindings(
          Platform.isIOS
              ? DynamicLibrary.process()
              : DynamicLibrary.open(
                  NativeLibraryLoader.resolve(overridePath: libraryPath),
                ),
        );

  final DartMontyBindings _lib;

  @override
  int create(
    String code, {
    String? externalFunctions,
    String? scriptName,
  }) {
    final cCode = code.toNativeUtf8().cast<Char>();
    final cExtFns = externalFunctions != null
        ? externalFunctions.toNativeUtf8().cast<Char>()
        : nullptr.cast<Char>();
    final cScriptName = scriptName != null
        ? scriptName.toNativeUtf8().cast<Char>()
        : nullptr.cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final handle = _lib.monty_create(cCode, cExtFns, cScriptName, outError);
      if (handle == nullptr) {
        final errorMsg = _readAndFreeString(outError.value);
        throw StateError(errorMsg ?? 'monty_create returned null');
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
    _lib.monty_free(Pointer<MontyHandle>.fromAddress(handle));
  }

  @override
  RunResult run(int handle) {
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final outResult = calloc<Pointer<Char>>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_run(ptr, outResult, outError);
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
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_start(ptr, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc.free(outError);
    }
  }

  @override
  ProgressResult resume(int handle, String valueJson) {
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final cValue = valueJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_resume(ptr, cValue, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cValue)
        ..free(outError);
    }
  }

  @override
  ProgressResult resumeWithError(int handle, String errorMessage) {
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final cError = errorMessage.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_resume_with_error(ptr, cError, outError);

      return _buildProgressResult(ptr, tag, outError.value);
    } finally {
      calloc
        ..free(cError)
        ..free(outError);
    }
  }

  @override
  ProgressResult resumeAsFuture(int handle) {
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_resume_as_future(ptr, outError);

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
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final cResults = resultsJson.toNativeUtf8().cast<Char>();
    final cErrors = errorsJson.toNativeUtf8().cast<Char>();
    final outError = calloc<Pointer<Char>>();

    try {
      final tag = _lib.monty_resume_futures(ptr, cResults, cErrors, outError);

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
    _lib.monty_set_memory_limit(
      Pointer<MontyHandle>.fromAddress(handle),
      bytes,
    );
  }

  @override
  void setTimeLimitMs(int handle, int ms) {
    _lib.monty_set_time_limit_ms(
      Pointer<MontyHandle>.fromAddress(handle),
      ms,
    );
  }

  @override
  void setStackLimit(int handle, int depth) {
    _lib.monty_set_stack_limit(
      Pointer<MontyHandle>.fromAddress(handle),
      depth,
    );
  }

  @override
  Uint8List snapshot(int handle) {
    final ptr = Pointer<MontyHandle>.fromAddress(handle);
    final outLen = calloc<Size>();

    try {
      final buf = _lib.monty_snapshot(ptr, outLen);
      if (buf == nullptr) {
        throw StateError('monty_snapshot returned null');
      }
      final len = outLen.value;
      final bytes = Uint8List.fromList(buf.cast<Uint8>().asTypedList(len));
      _lib.monty_bytes_free(buf, len);

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
      final handle = _lib.monty_restore(cData, data.length, outError);
      if (handle == nullptr) {
        final errorMsg = _readAndFreeString(outError.value);
        throw StateError(errorMsg ?? 'monty_restore returned null');
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
    Pointer<MontyHandle> ptr,
    MontyProgressTag tag,
    Pointer<Char> errorPtr,
  ) {
    switch (tag) {
      case MontyProgressTag.MONTY_PROGRESS_COMPLETE:
        final resultJsonPtr = _lib.monty_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);
        final isError = _lib.monty_complete_is_error(ptr);

        return ProgressResult(
          tag: 0,
          resultJson: resultJson,
          isError: isError,
        );

      case MontyProgressTag.MONTY_PROGRESS_PENDING:
        final fnNamePtr = _lib.monty_pending_fn_name(ptr);
        final fnName = _readAndFreeString(fnNamePtr);
        final argsPtr = _lib.monty_pending_fn_args_json(ptr);
        final argsJson = _readAndFreeString(argsPtr);
        final kwargsPtr = _lib.monty_pending_fn_kwargs_json(ptr);
        final kwargsJson = _readAndFreeString(kwargsPtr);
        final callId = _lib.monty_pending_call_id(ptr);
        final methodCall = _lib.monty_pending_method_call(ptr);

        return ProgressResult(
          tag: 1,
          functionName: fnName,
          argumentsJson: argsJson,
          kwargsJson: kwargsJson,
          callId: callId,
          methodCall: methodCall == 1,
        );

      case MontyProgressTag.MONTY_PROGRESS_ERROR:
        final errorMsg = _readAndFreeString(errorPtr);
        // handle_exception sets state to Complete with full error JSON
        final resultJsonPtr = _lib.monty_complete_result_json(ptr);
        final resultJson = _readAndFreeString(resultJsonPtr);

        return ProgressResult(
          tag: 2,
          errorMessage: errorMsg,
          resultJson: resultJson,
        );

      case MontyProgressTag.MONTY_PROGRESS_RESOLVE_FUTURES:
        final callIdsPtr = _lib.monty_pending_future_call_ids(ptr);
        final callIdsJson = _readAndFreeString(callIdsPtr);

        return ProgressResult(tag: 3, futureCallIdsJson: callIdsJson);
    }
  }

  /// Reads a C string, converts to Dart string, and frees via
  /// `monty_string_free`. Returns `null` if the pointer is null.
  String? _readAndFreeString(Pointer<Char> ptr) {
    if (ptr == nullptr) return null;
    final str = ptr.cast<Utf8>().toDartString();
    _lib.monty_string_free(ptr);

    return str;
  }
}
