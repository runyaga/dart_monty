import 'package:dart_monty/src/extension/extension.dart' show MontyExtension;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';

/// Exposes the capabilities passed to [MontyExtension.onAttach] without bridge
/// execution.
abstract interface class AttachContext {
  /// Provides schemas registered before the current attachment.
  List<HostFunctionSchema> get schemas;

  /// Registers an OS handler when declarative prefix contributions are
  /// insufficient.
  void registerOs(OsHandler handler);
}
