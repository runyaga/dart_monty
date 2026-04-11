import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:meta/meta.dart';

/// Async handler that receives validated named arguments and returns a result.
typedef HostFunctionHandler =
    Future<Object?> Function(Map<String, Object?> args);

/// A host function: schema + handler + optional role.
@immutable
class HostFunction {
  /// Creates a [HostFunction].
  ///
  /// When [role] is provided, it is authoritative — the bridge uses it
  /// regardless of any `__role__` kwarg sent from Python. This prevents
  /// untrusted Python code from escalating to [InfraCall].
  ///
  /// When [role] is `null` (the default), the bridge falls back to the
  /// `__role__` kwarg from Python, defaulting to [ToolCall] if absent.
  const HostFunction({required this.schema, required this.handler, this.role});

  /// Describes name, parameters, and types.
  final HostFunctionSchema schema;

  /// Async handler invoked when Python calls this function.
  final HostFunctionHandler handler;

  /// Host-declared call role for middleware dispatch.
  ///
  /// When non-null, this overrides any `__role__` kwarg from Python.
  /// Use `const InfraCall()` for orchestration builtins that should
  /// bypass policy middleware.
  final CallRole? role;
}
