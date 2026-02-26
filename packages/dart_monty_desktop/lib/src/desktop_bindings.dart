import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Abstract interface over the desktop Isolate bridge.
///
/// All methods are `Future`-based because the Isolate round-trip is
/// inherently asynchronous. Unlike `WasmBindings` which returns raw JSON,
/// `DesktopBindings` returns already-decoded domain types because
/// `Isolate.spawn` creates same-group isolates that can send arbitrary
/// `@immutable` objects directly.
abstract class DesktopBindings {
  /// Initializes the background Isolate.
  ///
  /// Returns `true` if the Isolate spawned successfully.
  Future<bool> init();

  /// Runs Python [code] to completion in the background Isolate.
  ///
  /// If [scriptName] is non-null, it overrides the default filename in
  /// tracebacks and error messages.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  });

  /// Starts iterative execution of [code] in the background Isolate.
  ///
  /// If [scriptName] is non-null, it overrides the default filename.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  });

  /// Resumes a paused execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue);

  /// Resumes a paused execution by raising an error with [errorMessage].
  Future<MontyProgress> resumeWithError(String errorMessage);

  /// Converts the current pending call into a future and continues execution.
  Future<MontyProgress> resumeAsFuture();

  /// Resolves one or more pending futures with their [results], and
  /// optionally [errors].
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  });

  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot();

  /// Restores interpreter state from snapshot [data].
  Future<void> restore(Uint8List data);

  /// Disposes the background Isolate and frees resources.
  Future<void> dispose();
}
