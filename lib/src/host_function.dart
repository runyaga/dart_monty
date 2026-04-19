import 'package:dart_monty/src/host_function_schema.dart';
import 'package:meta/meta.dart';

/// Async handler that receives validated named arguments and returns a result.
typedef HostFunctionHandler =
    Future<Object?> Function(Map<String, Object?> args);

/// A host function: schema + handler + optional infra flag.
@immutable
class HostFunction {
  /// Creates a [HostFunction].
  ///
  /// Set [isInfra] to `true` for orchestration builtins that should bypass
  /// the interceptor (e.g. introspection, internal routing). Regular
  /// Python-callable tools should leave this as the default `false`.
  const HostFunction({
    required this.schema,
    required this.handler,
    this.isInfra = false,
  });

  /// Describes name, parameters, and types.
  final HostFunctionSchema schema;

  /// Async handler invoked when Python calls this function.
  final HostFunctionHandler handler;

  /// When `true`, calls to this function bypass the interceptor.
  final bool isInfra;
}
