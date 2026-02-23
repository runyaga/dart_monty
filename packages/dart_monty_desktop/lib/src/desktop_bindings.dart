import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Result of [DesktopBindings.run].
///
/// Wraps a [MontyResult] from the background Isolate.
final class DesktopRunResult {
  /// Creates a [DesktopRunResult].
  const DesktopRunResult({required this.result});

  /// The result from the Python execution.
  final MontyResult result;
}

/// Result of [DesktopBindings.start], [DesktopBindings.resume], and
/// [DesktopBindings.resumeWithError].
///
/// Wraps a [MontyProgress] from the background Isolate.
final class DesktopProgressResult {
  /// Creates a [DesktopProgressResult].
  const DesktopProgressResult({required this.progress});

  /// The progress state from the Isolate.
  final MontyProgress progress;
}

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
  Future<DesktopRunResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  });

  /// Starts iterative execution of [code] in the background Isolate.
  ///
  /// If [scriptName] is non-null, it overrides the default filename.
  Future<DesktopProgressResult> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  });

  /// Resumes a paused execution with [returnValue].
  Future<DesktopProgressResult> resume(Object? returnValue);

  /// Resumes a paused execution by raising an error with [errorMessage].
  Future<DesktopProgressResult> resumeWithError(String errorMessage);

  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot();

  /// Restores interpreter state from snapshot [data].
  Future<void> restore(Uint8List data);

  /// Disposes the background Isolate and frees resources.
  Future<void> dispose();
}
