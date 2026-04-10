import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty/src/wasm/wasm_bindings.dart';

/// Error type string sent by the Worker when a Rust panic occurs.
///
/// The JS Worker sets `errorType: 'Panic'` on the message posted back
/// to Dart. This constant must match the Worker-side string exactly.
/// See: `packages/dart_monty_wasm/js/src/worker_src.js`.
const wasmPanicErrorType = 'Panic';

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
  int? _sessionId;

  @override
  Future<bool> init() async {
    if (_sessionId != null) return true;
    _sessionId = await _bindings.createSession();

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
    final sw = Stopwatch()..start();
    final progress = await _bindings.resumeAsFuture();
    sw.stop();

    return _translateProgressResult(progress, sw.elapsedMilliseconds);
  }

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    final sw = Stopwatch()..start();
    final progress = await _bindings.resolveFutures(resultsJson, errorsJson);
    sw.stop();

    return _translateProgressResult(progress, sw.elapsedMilliseconds);
  }

  @override
  Future<Uint8List> snapshot() {
    return _bindings.snapshot();
  }

  @override
  Future<void> restoreSnapshot(Uint8List data) async {
    // Ensure a session exists before restoring — _sessionId would be null
    // if restore is called on a fresh WasmCoreBindings instance.
    await init();
    await _bindings.restore(data);
  }

  @override
  Future<void> dispose() async {
    if (_sessionId != null) {
      await _bindings.disposeSession(_sessionId!);
      _sessionId = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Session invalidation
  // ---------------------------------------------------------------------------

  /// Invalidates the session after a WASM panic/trap.
  ///
  /// The Worker is likely dead, so we null [_sessionId] so that [init] can
  /// spawn a fresh one.
  void _invalidateSession() {
    _sessionId = null;
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
        printOutput: result.printOutput,
      );
    }
    // WASM trap (panic=abort) surfaces as errorType 'Panic' from the Worker.
    // Route to MontyPanicError so supervisors can pattern-match.
    if (result.errorType == wasmPanicErrorType) {
      _invalidateSession();
      throw MontyPanicError(result.error ?? 'WASM trap');
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
      // WASM trap (panic=abort) surfaces as errorType 'Panic' from the Worker.
      if (progress.errorType == wasmPanicErrorType) {
        _invalidateSession();
        throw MontyPanicError(progress.error ?? 'WASM trap');
      }

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
          printOutput: progress.printOutput,
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

      case 'os_call':
        return CoreProgressResult(
          state: 'os_call',
          functionName: progress.functionName ?? '',
          arguments: progress.arguments ?? const [],
          kwargs: progress.kwargs,
          callId: progress.callId ?? 0,
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
