import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/src/wasm_bindings.dart';

/// Adapts [WasmBindings] (async, [WasmRunResult]/[WasmProgressResult])
/// to the [MontyCoreBindings] interface (async, [CoreRunResult]/
/// [CoreProgressResult]).
///
/// Provides synthetic [MontyResourceUsage] with Dart-side wall-clock
/// timing since the WASM bridge does not expose `ResourceTracker`.
///
/// ```dart
/// final core = WasmCoreBindings(bindings: WasmBindingsJs());
/// final monty = MontyWasm(bindings: core);
/// ```
class WasmCoreBindings implements MontyCoreBindings {
  /// Creates a [WasmCoreBindings] backed by [bindings].
  WasmCoreBindings({required WasmBindings bindings}) : _bindings = bindings;

  final WasmBindings _bindings;
  bool _initialized = false;

  @override
  Future<bool> init() async {
    if (_initialized) return true;
    final ok = await _bindings.init();
    if (!ok) {
      throw StateError('Failed to initialize WASM Worker');
    }
    _initialized = true;
    return true;
  }

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    final sw = Stopwatch()..start();
    final result = await _bindings.run(
      code,
      limitsJson: limitsJson,
      scriptName: scriptName,
    );
    sw.stop();
    return _translateRunResult(result, sw.elapsedMilliseconds);
  }

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    final sw = Stopwatch()..start();
    final progress = await _bindings.start(
      code,
      extFnsJson: extFnsJson,
      limitsJson: limitsJson,
      scriptName: scriptName,
    );
    sw.stop();
    return _translateProgressResult(progress, sw.elapsedMilliseconds);
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    final sw = Stopwatch()..start();
    final progress = await _bindings.resume(valueJson);
    sw.stop();
    return _translateProgressResult(progress, sw.elapsedMilliseconds);
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    final sw = Stopwatch()..start();
    final progress = await _bindings.resumeWithError(errorMessage);
    sw.stop();
    return _translateProgressResult(progress, sw.elapsedMilliseconds);
  }

  @override
  Future<CoreProgressResult> resumeAsFuture() async {
    throw UnsupportedError('resumeAsFuture() not supported in WASM');
  }

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    throw UnsupportedError('resolveFutures() not supported in WASM');
  }

  @override
  Future<Uint8List> snapshot() => _bindings.snapshot();

  @override
  Future<void> restoreSnapshot(Uint8List data) => _bindings.restore(data);

  @override
  Future<void> dispose() async {
    if (_initialized) {
      await _bindings.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Translation helpers
  // ---------------------------------------------------------------------------

  static MontyResourceUsage _makeUsage(int elapsedMs) => MontyResourceUsage(
        memoryBytesUsed: 0,
        timeElapsedMs: elapsedMs,
        stackDepthUsed: 0,
      );

  CoreRunResult _translateRunResult(WasmRunResult result, int elapsedMs) {
    if (result.ok) {
      return CoreRunResult(
        ok: true,
        value: result.value,
        usage: _makeUsage(elapsedMs),
      );
    }
    return CoreRunResult(
      ok: false,
      error: result.error ?? 'Unknown error',
      excType: result.excType,
      traceback: result.traceback,
    );
  }

  CoreProgressResult _translateProgressResult(
    WasmProgressResult progress,
    int elapsedMs,
  ) {
    if (!progress.ok) {
      return CoreProgressResult(
        state: 'error',
        error: progress.error ?? 'Unknown error',
        excType: progress.excType,
        traceback: progress.traceback,
      );
    }

    switch (progress.state) {
      case 'complete':
        return CoreProgressResult(
          state: 'complete',
          value: progress.value,
          usage: _makeUsage(elapsedMs),
        );

      case 'pending':
        return CoreProgressResult(
          state: 'pending',
          functionName: progress.functionName ?? '',
          arguments: progress.arguments ?? const [],
          kwargs: progress.kwargs,
          callId: progress.callId ?? 0,
          methodCall: progress.methodCall ?? false,
        );

      case 'resolve_futures':
        return CoreProgressResult(
          state: 'resolve_futures',
          pendingCallIds: progress.pendingCallIds ?? const [],
        );

      default:
        throw StateError('Unknown progress state: ${progress.state}');
    }
  }
}
