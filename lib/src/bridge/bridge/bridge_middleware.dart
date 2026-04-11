/// Role of a tool call passing through the middleware chain.
///
/// Sealed so every `switch` is exhaustive — adding a new role subtype
/// is a compile-time breaking change that forces middleware updates.
sealed class CallRole {
  /// Creates a [CallRole].
  const CallRole();
}

/// Infrastructure: orchestration loop, planning, routing.
///
/// Middleware should observe but not enforce policy on these calls.
class InfraCall extends CallRole {
  /// Creates an [InfraCall].
  const InfraCall();
}

/// Agent-initiated tool action — subject to the full middleware chain.
class ToolCall extends CallRole {
  /// Creates a [ToolCall].
  const ToolCall();
}

/// Signature for the next handler in the middleware chain.
typedef ToolHandler =
    Future<Object?> Function(String name, Map<String, Object?> args);

/// Intercepts every tool call through a bridge.
///
/// Register via `use()` on the bridge. First registered = outermost in the
/// onion chain. Call `next` to proceed, or throw/return to short-circuit.
abstract class BridgeMiddleware {
  /// Wraps a tool call. Inspect [role] to decide whether to enforce policy.
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  );
}
