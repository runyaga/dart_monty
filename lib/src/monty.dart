import 'package:dart_monty/src/monty_factory.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Monty sandboxed Python interpreter.
///
/// {@category Core}
///
/// Uses compile-time conditional imports to select the backend:
/// - Native (macOS, Linux, Windows): Rust FFI via `dart:ffi`
/// - Web (browser): WASM via `dart:js_interop`
///
/// The backend is determined at compile time, not runtime — there is no
/// reflection or service locator. `dart compile` sees `dart.library.ffi`
/// or `dart.library.js_interop` and picks the corresponding import.
///
/// ```dart
/// final monty = Monty();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class Monty implements MontyPlatform {
  /// Creates a Monty interpreter with the auto-detected backend.
  factory Monty() => Monty._(createPlatformMonty());

  /// Creates a Monty interpreter with an explicit backend.
  ///
  /// Use this when you need a specific backend or custom bindings:
  /// ```dart
  /// final monty = Monty.withPlatform(MontyFfi(bindings: custom));
  /// ```
  factory Monty.withPlatform(MontyPlatform platform) => Monty._(platform);

  Monty._(this._platform);

  final MontyPlatform _platform;

  /// Access the underlying platform for capability checks.
  ///
  /// ```dart
  /// if (monty.platform is MontySnapshotCapable) { ... }
  /// ```
  MontyPlatform get platform => _platform;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) => _platform.run(code, limits: limits, scriptName: scriptName);

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) => _platform.start(
    code,
    externalFunctions: externalFunctions,
    limits: limits,
    scriptName: scriptName,
  );

  @override
  Future<MontyProgress> resume(Object? returnValue) =>
      _platform.resume(returnValue);

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _platform.resumeWithError(errorMessage);

  @override
  Future<void> cancel() => _platform.cancel();

  @override
  Future<void> dispose() => _platform.dispose();

  @override
  int? get handleId => _platform.handleId;
}
