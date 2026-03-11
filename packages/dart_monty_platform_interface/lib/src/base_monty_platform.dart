import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_platform_interface/src/core_bindings.dart';
import 'package:dart_monty_platform_interface/src/monty_cancel_token.dart';
import 'package:dart_monty_platform_interface/src/monty_error.dart';
import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_resource_usage.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:dart_monty_platform_interface/src/monty_stack_frame.dart';
import 'package:dart_monty_platform_interface/src/monty_state_mixin.dart';
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

  // ---------------------------------------------------------------------------
  // Native cancel callbacks (registered by dart_monty_ffi at init time)
  // ---------------------------------------------------------------------------

  static bool Function(int handleId)? _nativeCancelById;
  static bool? Function(int handleId)? _nativeIsCancelledById;
  static void Function([String? libraryPath])? _nativeEnsureInitialized;

  /// Register native cancel functions. Called by `dart_monty_ffi` at init.
  ///
  /// Since `dart_monty_platform_interface` cannot depend on `dart_monty_ffi`,
  /// the FFI package registers its cancel callbacks here at construction time.
  static void registerNativeCancel({
    required bool Function(int handleId) cancelById,
    required bool? Function(int handleId) isCancelledById,
    required void Function([String? libraryPath]) ensureInitialized,
  }) {
    _nativeCancelById = cancelById;
    _nativeIsCancelledById = isCancelledById;
    _nativeEnsureInitialized = ensureInitialized;
  }

  // ---------------------------------------------------------------------------
  // Web registry for cross-session cancelById
  // ---------------------------------------------------------------------------

  static final Map<int, MontyCoreBindings> _webRegistry = {};
  static int _webNextId = 1;

  /// Register a web bindings instance for cross-session cancel.
  /// Returns the assigned handle ID.
  static int webRegister(MontyCoreBindings bindings) {
    final id = _webNextId++;
    _webRegistry[id] = bindings;
    return id;
  }

  /// Unregister a web bindings instance.
  static void webUnregister(int handleId) {
    _webRegistry.remove(handleId);
  }

  // ---------------------------------------------------------------------------
  // Static cancel API
  // ---------------------------------------------------------------------------

  /// Cancel a handle by ID. Works cross-platform (native registry or web).
  ///
  /// Returns `true` if the handle was found and cancelled.
  static bool cancelById(int handleId) {
    if (_nativeCancelById != null) {
      return _nativeCancelById!(handleId);
    }
    return _webCancelById(handleId);
  }

  static bool _webCancelById(int handleId) {
    final bindings = _webRegistry[handleId];
    if (bindings == null) return false;
    unawaited(bindings.cancel());
    return true;
  }

  /// Ensure the native FFI library is loaded. No-op on web.
  static void ensureInitialized([String? libraryPath]) {
    _nativeEnsureInitialized?.call(libraryPath);
  }

  /// Check if a handle is still alive (registered and not freed).
  static bool isHandleAlive(int handleId) {
    if (_nativeIsCancelledById != null) {
      return _nativeIsCancelledById!(handleId) != null;
    }
    return _webRegistry.containsKey(handleId);
  }

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
  Future<void> cancel() async {
    if (isDisposed) return;
    await _bindings.cancel();
  }

  /// Returns a serializable cancel token for cross-isolate cancel.
  ///
  /// `null` before the first [run]/[start] (handle not yet created).
  MontyCancelToken? get cancelToken {
    final id = _bindings.handleId;
    return id != null && id > 0 ? MontyCancelToken(id) : null;
  }

  @override
  int? get handleId => _bindings.handleId;

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    final id = _bindings.handleId;
    if (id != null) webUnregister(id);
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
        error: _buildError(r.error, r.excType, r.traceback),
        usage: r.usage ?? _zeroUsage,
        printOutput: r.printOutput,
      );
    }
    _throwSealedErrorIfApplicable(r.excType, r.error ?? 'Unknown error');
    throw MontyException(
      message: r.error ?? 'Unknown error',
      excType: r.excType,
      traceback: _parseTraceback(r.traceback),
      filename: r.filename,
      lineNumber: r.lineNumber,
      columnNumber: r.columnNumber,
      sourceCode: r.sourceCode,
    );
  }

  /// Translates a [CoreProgressResult] into a [MontyProgress] domain type.
  @protected
  MontyProgress translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        markIdle();
        return MontyComplete(
          result: MontyResult(
            value: p.value,
            error: _buildError(p.error, p.excType, p.traceback),
            usage: p.usage ?? _zeroUsage,
            printOutput: p.printOutput,
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
        _throwSealedErrorIfApplicable(p.excType, p.error ?? 'Unknown error');
        throw MontyException(
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: _parseTraceback(p.traceback),
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

  /// Maps known Python exception types to the sealed [MontyError] hierarchy.
  ///
  /// Throws the appropriate sealed type for cancel and resource errors.
  /// Returns without throwing for unmapped types, allowing fallthrough to
  /// the existing [MontyException] path.
  void _throwSealedErrorIfApplicable(String? excType, String message) {
    switch (excType) {
      case 'KeyboardInterrupt':
        throw MontyCancelledError(message);
      case 'MemoryLimitExceeded':
        throw MontyResourceError(message);
      default:
        return;
    }
  }
}
