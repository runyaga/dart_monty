import 'package:dart_monty_bridge/src/bridge/host_function_schema.dart';
import 'package:meta/meta.dart';

/// Async handler that receives validated named arguments and returns a result.
typedef HostFunctionHandler = Future<Object?> Function(
  Map<String, Object?> args,
);

/// A host function: schema + handler.
@immutable
class HostFunction {
  /// Creates a [HostFunction].
  const HostFunction({
    required this.schema,
    required this.handler,
  });

  /// Describes name, parameters, and types.
  final HostFunctionSchema schema;

  /// Async handler invoked when Python calls this function.
  final HostFunctionHandler handler;
}
