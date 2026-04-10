import 'dart:typed_data';

import 'package:dart_monty_wasm/src/wasm_bindings.dart';

/// VM stub for [WasmBindingsJs].
///
/// On non-web platforms `dart:js_interop` is unavailable, so this stub
/// provides the same class name so that the conditional import in
/// `monty_wasm.dart` compiles. The constructor throws immediately — tests
/// always inject a mock, so this path is never reached.
class WasmBindingsJs extends WasmBindings {
  /// Throws [UnsupportedError] — only available on web.
  WasmBindingsJs() {
    throw UnsupportedError(
      'WasmBindingsJs requires dart:js_interop (web only)',
    );
  }

  @override
  Future<bool> init() => throw UnimplementedError();

  @override
  Future<int> createSession() => throw UnimplementedError();

  @override
  Future<void> disposeSession(int sessionId) => throw UnimplementedError();

  @override
  Future<WasmRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) =>
      throw UnimplementedError();

  @override
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) =>
      throw UnimplementedError();

  @override
  Future<WasmProgressResult> resume(String valueJson) =>
      throw UnimplementedError();

  @override
  Future<WasmProgressResult> resumeWithError(String errorMessage) =>
      throw UnimplementedError();

  @override
  Future<WasmProgressResult> resumeAsFuture() => throw UnimplementedError();

  @override
  Future<WasmProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> snapshot() => throw UnimplementedError();

  @override
  Future<void> restore(Uint8List data) => throw UnimplementedError();

  @override
  Future<WasmDiscoverResult> discover() => throw UnimplementedError();

  @override
  Future<void> dispose() => throw UnimplementedError();
}
