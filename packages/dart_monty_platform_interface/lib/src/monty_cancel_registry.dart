import 'dart:async';

import 'package:dart_monty_platform_interface/src/core_bindings.dart';

/// Cross-platform cancel and handle registry.
///
/// Provides static methods for cancelling interpreter handles by ID,
/// regardless of whether the handle lives in a native FFI isolate or a
/// web Worker. Native backends register their callbacks via
/// [registerNativeCancel]; web backends register individual bindings
/// via [webRegister]/[webUnregister].
///
/// This class is stateless — all state is held in static fields scoped
/// to the current isolate.
abstract final class MontyCancelRegistry {
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
  // Public cancel API
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
}
