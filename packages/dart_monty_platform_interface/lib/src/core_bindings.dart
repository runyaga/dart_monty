import 'dart:typed_data';

import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_resource_usage.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';

/// Intermediate result from [MontyCoreBindings.run].
///
/// Returned by bindings adapters before BaseMontyPlatform translates it
/// into a [MontyResult]. When [ok] is `true`, [value] and [usage] are
/// populated. When [ok] is `false`, [error], [excType], and [traceback]
/// describe the failure.
final class CoreRunResult {
  /// Creates a [CoreRunResult].
  const CoreRunResult({
    required this.ok,
    this.value,
    this.usage,
    this.error,
    this.excType,
    this.traceback,
  });

  /// Whether the execution succeeded.
  final bool ok;

  /// The Python return value (when [ok] is `true`).
  final Object? value;

  /// Resource usage statistics (when available).
  final MontyResourceUsage? usage;

  /// Error message (when [ok] is `false`).
  final String? error;

  /// Python exception type name, e.g. `'ValueError'` (when [ok] is `false`).
  final String? excType;

  /// Raw traceback frames (when [ok] is `false`).
  final List<dynamic>? traceback;
}

/// Intermediate result from [MontyCoreBindings] progress methods.
///
/// Returned by bindings adapters before BaseMontyPlatform translates it
/// into a [MontyProgress]. The [state] field determines which fields are
/// populated:
///
/// - `'complete'` — [value] holds the Python return value.
/// - `'pending'` — [functionName], [arguments], [kwargs], [callId], and
///   [methodCall] describe the external function call.
/// - `'resolve_futures'` — [pendingCallIds] lists call IDs awaiting
///   resolution.
///
/// When an error occurs, [error], [excType], and [traceback] are populated
/// regardless of [state].
final class CoreProgressResult {
  /// Creates a [CoreProgressResult].
  const CoreProgressResult({
    required this.state,
    this.value,
    this.functionName,
    this.arguments,
    this.kwargs,
    this.callId,
    this.methodCall,
    this.pendingCallIds,
    this.error,
    this.excType,
    this.traceback,
  });

  /// Progress state: `'complete'`, `'pending'`, or `'resolve_futures'`.
  final String state;

  /// Python return value (when [state] is `'complete'`).
  final Object? value;

  /// External function name (when [state] is `'pending'`).
  final String? functionName;

  /// Positional arguments (when [state] is `'pending'`).
  final List<Object?>? arguments;

  /// Keyword arguments (when [state] is `'pending'`).
  final Map<String, Object?>? kwargs;

  /// Unique call identifier (when [state] is `'pending'`).
  final int? callId;

  /// Whether this is a method call (when [state] is `'pending'`).
  final bool? methodCall;

  /// Call IDs awaiting resolution (when [state] is `'resolve_futures'`).
  final List<int>? pendingCallIds;

  /// Error message (when execution failed).
  final String? error;

  /// Python exception type name (when execution failed).
  final String? excType;

  /// Raw traceback frames (when execution failed).
  final List<dynamic>? traceback;
}

/// Unified bindings contract for Monty backends.
///
/// Both FFI and WASM adapters implement this interface.
/// BaseMontyPlatform delegates to a [MontyCoreBindings] and translates
/// [CoreRunResult] / [CoreProgressResult] into domain types
/// ([MontyResult], [MontyProgress], [MontyException]).
///
/// Methods accept JSON-level data (strings for limits, external functions,
/// resume values) — adapters handle serialization details specific to
/// their transport (FFI handles vs WASM Worker messages).
abstract class MontyCoreBindings {
  /// Initializes the backend (Isolate, Worker, etc.).
  ///
  /// Returns `true` on success. Implementations should be idempotent.
  Future<bool> init();

  /// Runs [code] to completion and returns the result.
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  });

  /// Starts iterative execution of [code] with optional external functions.
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  });

  /// Resumes execution with [valueJson] as the return value.
  Future<CoreProgressResult> resume(String valueJson);

  /// Resumes execution, injecting [errorMessage] as a Python exception.
  Future<CoreProgressResult> resumeWithError(String errorMessage);

  /// Resumes execution, converting the pending call into a future.
  Future<CoreProgressResult> resumeAsFuture();

  /// Resolves pending futures with [resultsJson] and optional [errorsJson].
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  );

  /// Captures the current execution state as a snapshot.
  Future<Uint8List> snapshot();

  /// Restores execution state from [data].
  Future<void> restoreSnapshot(Uint8List data);

  /// Releases all resources held by this bindings instance.
  Future<void> dispose();
}
