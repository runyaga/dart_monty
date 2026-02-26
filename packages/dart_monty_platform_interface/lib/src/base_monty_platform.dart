import 'dart:convert';

import 'package:dart_monty_platform_interface/src/core_bindings.dart';
import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_resource_usage.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:dart_monty_platform_interface/src/monty_stack_frame.dart';
import 'package:dart_monty_platform_interface/src/monty_state_mixin.dart';

/// Abstract base that implements [MontyPlatform] by delegating to a
/// [MontyCoreBindings] and translating intermediate results into
/// domain types.
///
/// Subclasses provide a concrete [MontyCoreBindings] adapter and
/// override [backendName]:
///
/// ```dart
/// class MontyFfi extends BaseMontyPlatform {
///   MontyFfi() : super(bindings: FfiCoreBindings());
///   @override
///   String get backendName => 'MontyFfi';
/// }
/// ```
abstract class BaseMontyPlatform extends MontyPlatform with MontyStateMixin {
  /// Creates a [BaseMontyPlatform] backed by [bindings].
  BaseMontyPlatform({required MontyCoreBindings bindings})
      : _bindings = bindings;

  final MontyCoreBindings _bindings;

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  bool _initialized = false;

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
    final result = await _bindings.run(
      code,
      limitsJson: _encodeLimits(limits),
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
    final progress = await _bindings.start(
      code,
      extFnsJson: _encodeExternalFunctions(externalFunctions),
      limitsJson: _encodeLimits(limits),
      scriptName: scriptName,
    );
    return _translateProgress(progress);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');
    final progress = await _bindings.resume(
      json.encode(returnValue),
    );
    return _translateProgress(progress);
  }

  @override
  Future<MontyProgress> resumeWithError(
    String errorMessage,
  ) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');
    final progress = await _bindings.resumeWithError(
      errorMessage,
    );
    return _translateProgress(progress);
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    await _bindings.dispose();
    markDisposed();
  }

  // -- Private translation helpers --

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await _bindings.init();
      _initialized = true;
    }
  }

  MontyResult _translateRunResult(CoreRunResult r) {
    if (r.ok) {
      return MontyResult(
        value: r.value,
        usage: r.usage ?? _zeroUsage,
        printOutput: r.printOutput,
      );
    }
    throw MontyException(
      message: r.error ?? 'Unknown error',
      excType: r.excType,
      traceback: _parseTraceback(r.traceback),
    );
  }

  MontyProgress _translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        markIdle();
        return MontyComplete(
          result: MontyResult(
            value: p.value,
            usage: p.usage ?? _zeroUsage,
          ),
        );
      case 'pending':
        markActive();
        return MontyPending(
          functionName: p.functionName ?? '',
          arguments: p.arguments ?? const [],
          kwargs: p.kwargs,
          callId: p.callId ?? 0,
          methodCall: p.methodCall ?? false,
        );
      case 'resolve_futures':
        markActive();
        return MontyResolveFutures(
          pendingCallIds: p.pendingCallIds ?? const [],
        );
      case 'error':
        markIdle();
        throw MontyException(
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: _parseTraceback(p.traceback),
        );
      default:
        markIdle();
        throw StateError(
          'Unknown progress state: ${p.state}',
        );
    }
  }

  String? _encodeLimits(MontyLimits? limits) {
    if (limits == null) return null;
    return json.encode(limits.toJson());
  }

  String? _encodeExternalFunctions(List<String>? fns) {
    if (fns == null || fns.isEmpty) return null;
    return json.encode(fns);
  }

  List<MontyStackFrame> _parseTraceback(
    List<dynamic>? traceback,
  ) {
    if (traceback == null) return const [];
    return MontyStackFrame.listFromJson(traceback);
  }
}
