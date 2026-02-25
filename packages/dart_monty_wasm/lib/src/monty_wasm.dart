import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/src/wasm_bindings.dart';

/// Web WASM implementation of [MontyPlatform].
///
/// Uses a [WasmBindings] abstraction to call into the WASM Worker bridge.
/// Manages a state machine: idle -> active -> disposed.
///
/// ```dart
/// final monty = MontyWasm(bindings: WasmBindingsJs());
/// await monty.initialize();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyWasm extends MontyPlatform with MontyStateMixin {
  /// Creates a [MontyWasm] with the given [bindings].
  MontyWasm({required WasmBindings bindings}) : _bindings = bindings;

  @override
  String get backendName => 'MontyWasm';

  final WasmBindings _bindings;
  bool _initialized = false;

  /// Synthetic resource usage — the WASM bridge does not expose
  /// `ResourceTracker` data yet.
  static const _syntheticUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  /// Initializes the WASM Worker.
  ///
  /// Must be called before any execution methods. Initialization is
  /// idempotent — subsequent calls return immediately.
  ///
  /// Throws [StateError] if the Worker fails to load.
  Future<void> initialize() async {
    if (_initialized) return;
    final ok = await _bindings.init();
    if (!ok) {
      throw StateError('Failed to initialize WASM Worker');
    }
    _initialized = true;
  }

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    rejectInputs(inputs);
    await _ensureInitialized();

    final limitsJson = _encodeLimits(limits);
    final result = await _bindings.run(
      code,
      limitsJson: limitsJson,
      scriptName: scriptName,
    );

    return _translateRunResult(result);
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    rejectInputs(inputs);
    await _ensureInitialized();

    final extFnsJson = externalFunctions != null && externalFunctions.isNotEmpty
        ? json.encode(externalFunctions)
        : null;
    final limitsJson = _encodeLimits(limits);

    final progress = await _bindings.start(
      code,
      extFnsJson: extFnsJson,
      limitsJson: limitsJson,
      scriptName: scriptName,
    );

    return _translateProgress(progress);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');

    final valueJson = json.encode(returnValue);
    final progress = await _bindings.resume(valueJson);

    return _translateProgress(progress);
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    final progress = await _bindings.resumeWithError(errorMessage);

    return _translateProgress(progress);
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    throw UnsupportedError(
      'resumeAsFuture() is not yet supported in the WASM backend. '
      'The @pydantic/monty NAPI-RS WASM module does not expose the '
      'FutureSnapshot API.',
    );
  }

  @override
  Future<MontyProgress> resolveFutures(Map<int, Object?> results) async {
    throw UnsupportedError(
      'resolveFutures() is not yet supported in the WASM backend. '
      'The @pydantic/monty NAPI-RS WASM module does not expose the '
      'FutureSnapshot API.',
    );
  }

  @override
  Future<MontyProgress> resolveFuturesWithErrors(
    Map<int, Object?> results,
    Map<int, String> errors,
  ) async {
    throw UnsupportedError(
      'resolveFuturesWithErrors() is not yet supported in the WASM backend. '
      'The @pydantic/monty NAPI-RS WASM module does not expose the '
      'FutureSnapshot API.',
    );
  }

  @override
  Future<Uint8List> snapshot() {
    assertNotDisposed('snapshot');
    assertActive('snapshot');

    return _bindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    assertNotDisposed('restore');
    assertIdle('restore');

    await _bindings.restore(data);

    return MontyWasm(bindings: _bindings)
      .._initialized = _initialized
      ..markActive();
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;

    if (_initialized) {
      await _bindings.dispose();
    }
    markDisposed();
  }

  // ---------------------------------------------------------------------------
  // Private methods
  // ---------------------------------------------------------------------------

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  MontyResult _translateRunResult(WasmRunResult result) {
    if (result.ok) {
      return MontyResult(
        value: result.value,
        usage: _syntheticUsage,
      );
    }
    throw MontyException(
      message: result.error ?? 'Unknown error',
      excType: result.excType,
      traceback: _parseTraceback(result.traceback),
    );
  }

  MontyProgress _translateProgress(WasmProgressResult progress) {
    if (!progress.ok) {
      markIdle();
      throw MontyException(
        message: progress.error ?? 'Unknown error',
        excType: progress.excType,
        traceback: _parseTraceback(progress.traceback),
      );
    }

    switch (progress.state) {
      case 'complete':
        markIdle();

        return MontyComplete(
          result: MontyResult(
            value: progress.value,
            usage: _syntheticUsage,
          ),
        );

      case 'pending':
        markActive();

        return MontyPending(
          functionName: progress.functionName ?? '',
          arguments: progress.arguments ?? const [],
          kwargs: progress.kwargs,
          callId: progress.callId ?? 0,
          methodCall: progress.methodCall ?? false,
        );

      case 'resolve_futures':
        markActive();

        return MontyResolveFutures(
          pendingCallIds: progress.pendingCallIds ?? const [],
        );

      default:
        markIdle();
        throw StateError('Unknown progress state: ${progress.state}');
    }
  }

  String? _encodeLimits(MontyLimits? limits) {
    if (limits == null) return null;
    final map = <String, dynamic>{};
    if (limits.memoryBytes case final bytes?) {
      map['memory_bytes'] = bytes;
    }
    if (limits.timeoutMs case final ms?) {
      map['timeout_ms'] = ms;
    }
    if (limits.stackDepth case final depth?) {
      map['stack_depth'] = depth;
    }
    if (map.isEmpty) return null;

    return json.encode(map);
  }

  List<MontyStackFrame> _parseTraceback(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return const [];

    return MontyStackFrame.listFromJson(raw);
  }
}
