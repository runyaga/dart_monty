import 'package:dart_monty/src/platform/core_bindings.dart';

/// Internal bindings interface for REPL operations.
///
/// Implemented by `FfiReplBindings` and `WasmReplBindings` to provide
/// a unified contract across native FFI and web WASM backends.
abstract class ReplBindings {
  /// Creates a persistent REPL session.
  Future<void> create({String? scriptName});

  /// Feeds a Python snippet and runs to completion.
  ///
  /// Returns a [CoreRunResult] in the same format as one-shot execution.
  Future<CoreRunResult> feedRun(String code);

  /// Detects whether a source fragment is complete or needs more input.
  ///
  /// Returns `0` = complete, `1` = incomplete, `2` = incomplete block.
  Future<int> detectContinuation(String source);

  /// Registers external function names for name resolution.
  void setExtFns(List<String> names);

  /// Starts iterative execution. Pauses at external function calls.
  Future<CoreProgressResult> feedStart(String code);

  /// Resumes with a JSON-encoded return value.
  Future<CoreProgressResult> resume(String valueJson);

  /// Resumes by raising an error in Python.
  Future<CoreProgressResult> resumeWithError(String errorMessage);

  /// Disposes the REPL session.
  Future<void> dispose();
}
