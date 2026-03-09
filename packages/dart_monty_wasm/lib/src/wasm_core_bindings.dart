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
/// Registers in [BaseMontyPlatform.webRegister] at init for cross-session
/// `cancelById` support on web.
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
  int? _handleId;

  @override
  int? get handleId => _handleId;

  @override
  Future<bool> init() async {
    if (_sessionId != null) return true;
    _sessionId = await _bindings.createSession();
    _handleId = BaseMontyPlatform.webRegister(this);
    return true;
  }

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await _bindings.run(
        code,
        limitsJson: limitsJson,
        scriptName: scriptName,
      );
      sw.stop();
      return _translateRunResult(result, sw.elapsedMilliseconds);
    } on Object catch (e) {
      _throwIfWebCancelError(e);
      rethrow;
    }
  }

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final progress = await _bindings.start(
        code,
        extFnsJson: extFnsJson,
        limitsJson: limitsJson,
        scriptName: scriptName,
      );
      sw.stop();
      return _translateProgressResult(progress, sw.elapsedMilliseconds);
    } on Object catch (e) {
      _throwIfWebCancelError(e);
      rethrow;
    }
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    final sw = Stopwatch()..start();
    try {
      final progress = await _bindings.resume(valueJson);
      sw.stop();
      return _translateProgressResult(progress, sw.elapsedMilliseconds);
    } on Object catch (e) {
      _throwIfWebCancelError(e);
      rethrow;
    }
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    final sw = Stopwatch()..start();
    try {
      final progress = await _bindings.resumeWithError(errorMessage);
      sw.stop();
      return _translateProgressResult(progress, sw.elapsedMilliseconds);
    } on Object catch (e) {
      _throwIfWebCancelError(e);
      rethrow;
    }
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
  Future<void> restoreSnapshot(Uint8List data) async {
    // Ensure a session exists before restoring — _sessionId would be null
    // if restore is called on a fresh WasmCoreBindings instance.
    await init();
    await _bindings.restore(data);
  }

  @override
  Future<void> cancel() async {
    await _bindings.cancel();
  }

  @override
  Future<void> dispose() async {
    if (_handleId != null) {
      BaseMontyPlatform.webUnregister(_handleId!);
      _handleId = null;
    }
    if (_sessionId != null) {
      await _bindings.disposeSession(_sessionId!);
      _sessionId = null;
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
        printOutput: result.printOutput,
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

      case 'resolve_futures':
        return CoreProgressResult(
          state: 'resolve_futures',
          pendingCallIds: progress.pendingCallIds ?? const [],
        );

      default:
        throw StateError('Unknown progress state: ${progress.state}');
    }
  }

  // ---------------------------------------------------------------------------
  // Web error prefix mapping
  // ---------------------------------------------------------------------------

  /// Maps JS rejection error messages to sealed [MontyError] subtypes.
  ///
  /// When cancel() terminates the Worker, pending Promises reject with
  /// prefixed error messages. This method recognizes those prefixes and
  /// throws the appropriate sealed type so supervisors can pattern-match.
  void _throwIfWebCancelError(Object error) {
    final msg = error.toString();
    if (msg.contains('MontyCancelled:')) {
      throw MontyCancelledError(msg);
    }
    if (msg.contains('MontyDisposed:')) {
      throw MontyDisposedError(msg);
    }
    if (msg.contains('MontyWorkerError:')) {
      throw MontyResourceError(msg);
    }
  }
}
