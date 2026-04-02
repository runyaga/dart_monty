import 'package:dart_monty_platform_interface/src/monty_cancel_registry.dart';

/// Opaque, serializable token for cross-isolate cancel.
///
/// Wraps the monotonic handle ID for type safety.
/// Safe to send via SendPort. Immutable.
///
/// {@category Sessions}
extension type const MontyCancelToken(int id) {
  /// Cancel the interpreter this token refers to.
  ///
  /// Returns `true` if the handle was found and cancelled.
  bool cancel() => MontyCancelRegistry.cancelById(id);

  /// Check if the target interpreter handle is still alive.
  bool get isAlive => MontyCancelRegistry.isHandleAlive(id);
}
