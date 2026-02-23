/// Web implementation of dart_monty.
///
/// This package registers [DartMontyWeb] as the web platform implementation
/// of the dart_monty federated plugin. It delegates to `dart_monty_wasm`
/// for WASM-based Python execution via a Web Worker.
///
/// This package is not intended for direct use — import `dart_monty` instead.
library;

import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:meta/meta.dart';

/// Web implementation of [MontyPlatform].
///
/// Registers itself as the platform instance when running in a browser.
/// Delegates all execution to [MontyWasm] via [WasmBindingsJs].
class DartMontyWeb extends MontyPlatform {
  /// Creates a [DartMontyWeb].
  DartMontyWeb() : _delegate = MontyWasm(bindings: WasmBindingsJs());

  /// Creates a [DartMontyWeb] with injected [bindings] for testing.
  @visibleForTesting
  DartMontyWeb.withBindings(WasmBindings bindings)
      : _delegate = MontyWasm(bindings: bindings);

  final MontyWasm _delegate;

  /// Registers this class as the default [MontyPlatform] instance.
  static void registerWith(Registrar registrar) {
    MontyPlatform.instance = DartMontyWeb();
  }

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) =>
      _delegate.run(
        code,
        inputs: inputs,
        limits: limits,
        scriptName: scriptName,
      );

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) =>
      _delegate.start(
        code,
        inputs: inputs,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      );

  @override
  Future<MontyProgress> resume(Object? returnValue) =>
      _delegate.resume(returnValue);

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _delegate.resumeWithError(errorMessage);

  @override
  Future<MontyProgress> resumeAsFuture() {
    throw UnsupportedError(
      'resumeAsFuture() is not supported on web. '
      'The @pydantic/monty WASM runtime does not expose the FutureSnapshot API.',
    );
  }

  @override
  Future<MontyProgress> resolveFutures(Map<int, Object?> results) {
    throw UnsupportedError(
      'resolveFutures() is not supported on web. '
      'The @pydantic/monty WASM runtime does not expose the FutureSnapshot API.',
    );
  }

  @override
  Future<MontyProgress> resolveFuturesWithErrors(
    Map<int, Object?> results,
    Map<int, String> errors,
  ) {
    throw UnsupportedError(
      'resolveFuturesWithErrors() is not supported on web. '
      'The @pydantic/monty WASM runtime does not expose the FutureSnapshot API.',
    );
  }

  @override
  Future<Uint8List> snapshot() => _delegate.snapshot();

  @override
  Future<MontyPlatform> restore(Uint8List data) => _delegate.restore(data);

  @override
  Future<void> dispose() => _delegate.dispose();
}
