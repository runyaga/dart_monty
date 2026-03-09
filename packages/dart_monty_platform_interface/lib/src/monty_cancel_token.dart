import 'package:dart_monty_platform_interface/src/base_monty_platform.dart';

/// Opaque, serializable token for cross-isolate cancel.
///
/// Wraps the monotonic handle ID for type safety.
/// Safe to send via SendPort. Immutable.
extension type const MontyCancelToken(int id) {
  /// Cancel the interpreter this token refers to.
  ///
  /// Returns `true` if the handle was found and cancelled.
  bool cancel() => BaseMontyPlatform.cancelById(id);

  /// Check if the target interpreter handle is still alive.
  bool get isAlive => BaseMontyPlatform.isHandleAlive(id);
}
