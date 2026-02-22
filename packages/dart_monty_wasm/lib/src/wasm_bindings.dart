import 'dart:typed_data';

/// Result of [WasmBindings.run].
///
/// Contains either a successful value or an error message.
final class WasmRunResult {
  /// Creates a [WasmRunResult].
  const WasmRunResult({
    required this.ok,
    this.value,
    this.error,
    this.errorType,
  });

  /// Whether the execution succeeded.
  final bool ok;

  /// The return value from the Python execution (when [ok] is true).
  final Object? value;

  /// The error message (when [ok] is false).
  final String? error;

  /// The error type name (when [ok] is false).
  final String? errorType;
}

/// Result of [WasmBindings.start], [WasmBindings.resume], and
/// [WasmBindings.resumeWithError].
///
/// Contains a progress state and, depending on the state, accessor data.
final class WasmProgressResult {
  /// Creates a [WasmProgressResult].
  const WasmProgressResult({
    required this.ok,
    this.state,
    this.value,
    this.functionName,
    this.arguments,
    this.error,
    this.errorType,
  });

  /// Whether the operation succeeded.
  final bool ok;

  /// `'complete'` or `'pending'` (when [ok] is true).
  final String? state;

  /// The return value (when state is `'complete'`).
  final Object? value;

  /// The external function name (when state is `'pending'`).
  final String? functionName;

  /// The function arguments (when state is `'pending'`).
  final List<Object?>? arguments;

  /// The error message (when [ok] is false).
  final String? error;

  /// The error type name (when [ok] is false).
  final String? errorType;
}

/// Result of [WasmBindings.discover].
///
/// Describes the state of the WASM bridge.
final class WasmDiscoverResult {
  /// Creates a [WasmDiscoverResult].
  const WasmDiscoverResult({
    required this.loaded,
    required this.architecture,
  });

  /// Whether the WASM module is loaded.
  final bool loaded;

  /// The bridge architecture (e.g. `'worker'`).
  final String architecture;
}

/// Abstract interface over the WASM bridge.
///
/// All methods are `Future`-based because the Worker round-trip is
/// inherently asynchronous. Unlike native bindings, there are no integer
/// handles — the Worker holds the session state internally.
///
/// Resource limits are passed inline with `run()` / `start()` calls
/// rather than via separate `setLimit` calls, avoiding extra Worker
/// round-trips.
abstract class WasmBindings {
  /// Creates a [WasmBindings].
  WasmBindings();

  /// Initializes the WASM Worker.
  ///
  /// Returns `true` if the Worker loaded successfully.
  Future<bool> init();

  /// Runs Python [code] to completion.
  ///
  /// If [limitsJson] is non-null, it is a JSON-encoded map of limits.
  Future<WasmRunResult> run(String code, {String? limitsJson});

  /// Starts iterative execution of [code].
  ///
  /// If [extFnsJson] is non-null, it is a JSON array of external function
  /// names. If [limitsJson] is non-null, it is a JSON-encoded map of limits.
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
  });

  /// Resumes a paused execution with a JSON-encoded return [valueJson].
  Future<WasmProgressResult> resume(String valueJson);

  /// Resumes a paused execution with an [errorMessage].
  Future<WasmProgressResult> resumeWithError(String errorMessage);

  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot();

  /// Restores interpreter state from snapshot [data].
  Future<void> restore(Uint8List data);

  /// Discovers the bridge API surface.
  Future<WasmDiscoverResult> discover();

  /// Disposes the current Worker session.
  Future<void> dispose();
}
