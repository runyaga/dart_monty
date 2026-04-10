import 'dart:convert';

import 'package:dart_monty/src/platform/core_bindings.dart';
import 'package:dart_monty/src/platform/monty_error.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_stack_frame.dart';
import 'package:dart_monty/src/platform/monty_state_mixin.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:meta/meta.dart';

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

  /// The underlying bindings adapter for subclass use.
  @protected
  MontyCoreBindings get coreBindings => _bindings;

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  bool _initialized = false;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    markActive();
    try {
      await _ensureInitialized();
      final result = await _bindings.run(
        code,
        limitsJson: _encodeLimits(limits),
        scriptName: scriptName,
      );

      return _translateRunResult(result);
    } finally {
      markIdle();
    }
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    markActive();
    try {
      await _ensureInitialized();
      final progress = await _bindings.start(
        code,
        extFnsJson: _encodeExternalFunctions(externalFunctions),
        limitsJson: _encodeLimits(limits),
        scriptName: scriptName,
      );

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');
    try {
      final progress = await _bindings.resume(json.encode(returnValue));

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');
    try {
      final progress = await _bindings.resumeWithError(errorMessage);

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    // Force idle if active — allows dispose during test teardown and
    // crash-recovery scenarios. The in-flight operation will fail on
    // next resume (handle already freed).
    if (isActive) markIdle();
    await _bindings.dispose();
    markDisposed();
  }

  /// Translates a [CoreProgressResult] into a [MontyProgress] domain type.
  @protected
  MontyProgress translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        markIdle();

        return MontyComplete(
          result: MontyResult(
            value: p.value != null ? MontyValue.fromJson(p.value) : null,
            error: _buildError(p.error, p.excType, p.traceback),
            usage: p.usage ?? _zeroUsage,
            printOutput: p.printOutput,
          ),
        );
      case 'pending':
        markActive();

        return MontyPending(
          functionName: p.functionName ?? '',
          arguments: p.arguments != null
              ? p.arguments!.map(MontyValue.fromJson).toList()
              : const [],
          kwargs: p.kwargs?.map(
            (k, v) => MapEntry(k, MontyValue.fromJson(v)),
          ),
          callId: p.callId ?? 0,
          methodCall: p.methodCall ?? false,
        );
      case 'os_call':
        markActive();

        return MontyOsCall(
          operationName: p.functionName ?? '',
          arguments: p.arguments != null
              ? p.arguments!.map(MontyValue.fromJson).toList()
              : const [],
          kwargs: p.kwargs?.map(
            (k, v) => MapEntry(k, MontyValue.fromJson(v)),
          ),
          callId: p.callId ?? 0,
        );
      case 'resolve_futures':
        markActive();

        return MontyResolveFutures(
          pendingCallIds: p.pendingCallIds ?? const [],
        );
      case 'error':
        markIdle();
        _throwError(
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: p.traceback,
          filename: p.filename,
          lineNumber: p.lineNumber,
          columnNumber: p.columnNumber,
          sourceCode: p.sourceCode,
        );
      default:
        markIdle();
        throw StateError('Unknown progress state: ${p.state}');
    }
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
        value: r.value != null ? MontyValue.fromJson(r.value) : null,
        error: _buildError(r.error, r.excType, r.traceback),
        usage: r.usage ?? _zeroUsage,
        printOutput: r.printOutput,
      );
    }
    _throwError(
      message: r.error ?? 'Unknown error',
      excType: r.excType,
      traceback: r.traceback,
      filename: r.filename,
      lineNumber: r.lineNumber,
      columnNumber: r.columnNumber,
      sourceCode: r.sourceCode,
    );
  }

  String? _encodeLimits(MontyLimits? limits) {
    if (limits == null) return null;
    final map = limits.toJson();
    if (map.isEmpty) return null;

    return json.encode(map);
  }

  String? _encodeExternalFunctions(List<String>? fns) {
    if (fns == null || fns.isEmpty) return null;

    return json.encode(fns);
  }

  MontyException? _buildError(
    String? error,
    String? excType,
    List<dynamic>? traceback,
  ) {
    if (error == null) return null;

    return MontyException(
      message: error,
      excType: excType,
      traceback: _parseTraceback(traceback),
    );
  }

  List<MontyStackFrame> _parseTraceback(List<dynamic>? traceback) {
    if (traceback == null) return const [];

    return MontyStackFrame.listFromJson(traceback);
  }

  /// Throws the appropriate sealed [MontyError] subtype for a failed run.
  ///
  /// Resource errors (MemoryLimitExceeded) throw [MontyResourceError].
  /// All other Python exceptions throw [MontyScriptError] wrapping a full
  /// [MontyException] with traceback and source location details.
  Never _throwError({
    required String message,
    String? excType,
    List<dynamic>? traceback,
    String? filename,
    int? lineNumber,
    int? columnNumber,
    String? sourceCode,
  }) {
    // Resource exhaustion — separate sealed type.
    if (excType == 'MemoryLimitExceeded') {
      throw MontyResourceError(message);
    }

    // All other Python exceptions go through MontyScriptError.
    final exception = MontyException(
      message: message,
      excType: excType,
      traceback: _parseTraceback(traceback),
      filename: filename,
      lineNumber: lineNumber,
      columnNumber: columnNumber,
      sourceCode: sourceCode,
    );
    throw MontyScriptError(
      message,
      excType: excType,
      exception: exception,
    );
  }
}
