# Bridge Middleware

Cross-cutting policy enforcement at the tool dispatch chokepoint.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md)
(plugins, registry) and the [Advanced guide](host-functions-advanced.md)
(SandboxPlugin, production patterns) first.

## The Problem

Every tool call from Python passes through `DefaultMontyBridge`. Before
middleware, adding cross-cutting behaviour -- telemetry, rate limiting,
access control, grounding -- meant wrapping individual plugin handlers.
That approach scatters policy across dozens of functions, breaks when
plugins are added, and is invisible to other plugins.

`BridgeMiddleware` intercepts **every** tool call at the dispatch level,
in an onion-style chain identical to HTTP middleware in Express, Shelf,
or ASP.NET Core.

## Architecture

```text
Python call
    |
    v
DefaultMontyBridge._dispatch()
    |
    v  +--------------------------------------+
       |  Middleware Chain (onion model)       |
       |                                      |
       |  +- MW1 (outermost, first registered)|
       |  |   +- MW2                          |
       |  |   |   +- MW3 (innermost, last)    |
       |  |   |   |   Plugin Handler          |
       |  |   |   +---------------------------+
       |  |   +-------------------------------+
       |  +-----------------------------------+
       +--------------------------------------+
    |
    v
Result -> Python
```

Registration order determines nesting: **first registered = outermost**.
When no middleware is registered, the bridge takes a fast path that calls
the handler directly with zero overhead.

## CallRole: Sealed Discrimination

Not all tool calls are equal. A sealed `CallRole` hierarchy lets
middleware distinguish orchestration infrastructure from agent-initiated
actions:

```dart
sealed class CallRole {
  const CallRole();
}

/// Orchestration loop, planning, routing.
/// Middleware should observe but not enforce policy.
class InfraCall extends CallRole {
  const InfraCall();
}

/// Agent-initiated tool action -- full policy enforcement.
class ToolCall extends CallRole {
  const ToolCall();
}
```

Python signals the role via a reserved `__role__` kwarg. Typically, a
Python orchestration harness (seed code, prelude) injects `__role__`
during planning or routing calls. LLM-generated tool calls omit it:

```python
# Infrastructure call -- middleware observes only
result = list_functions(__role__="infra")

# Tool call (default when __role__ is omitted)
data = df_create(data=rows)
```

The bridge strips `__role__` before dispatching to the handler -- plugins
never see it. When omitted or set to an unrecognized value, the default
is `ToolCall`.

### Why sealed?

Adding a new `CallRole` subtype is a **compile-time breaking change**.
Every `switch (role)` in every middleware must handle the new case. Policy
gaps are caught at build time, not in production.

### Security: `__role__` is caller-asserted

**`__role__` is set by Python code, not by the bridge.** If your Python
code is LLM-generated or otherwise untrusted, the agent can send
`__role__="infra"` to bypass middleware policy. Mitigations:

- **Do not rely solely on `CallRole` for security.** Use it for
  observability and soft policy, not hard security boundaries.
- **Strip `__role__` in your seed/prelude code** before the LLM sees the
  function signatures, so the LLM never learns the kwarg exists.
- **Use a separate bridge** for infrastructure calls if hard isolation
  between infra and agent tool calls is required.

## Writing Middleware

Implement `BridgeMiddleware` with a single `handle` method:

```dart
abstract class BridgeMiddleware {
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  );
}
```

- **`name`** -- the host function name (e.g. `df_create`)
- **`args`** -- validated argument map (after schema coercion)
- **`role`** -- `InfraCall` or `ToolCall`
- **`next`** -- calls the next middleware (or the handler if innermost)

Three rules:

1. **Call `next(name, args)` to proceed.** Omitting it short-circuits the
   chain and returns your value directly to Python.
2. **Throw to reject.** The exception surfaces as a Python `RuntimeError`
   via the bridge's `resumeWithError()` path.
3. **Inspect `role` for selective enforcement.** Infra calls should
   generally pass through; tool calls are where you enforce policy.

### Example: Telemetry

```dart
class TelemetryMiddleware extends BridgeMiddleware {
  final durations = <String, List<Duration>>{};

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    final sw = Stopwatch()..start();
    try {
      return await next(name, args);
    } finally {
      sw.stop();
      durations.putIfAbsent(name, () => []).add(sw.elapsed);
    }
  }
}
```

This records latency for every tool call regardless of role. Because it
always calls `next`, it never blocks execution.

### Example: Rate Limiter

Enforce a per-second call limit, but only on agent tool calls:

```dart
class RateLimitMiddleware extends BridgeMiddleware {
  RateLimitMiddleware({required this.maxPerSecond});

  final int maxPerSecond;
  final _timestamps = <DateTime>[];

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    if (role is ToolCall) {
      final now = DateTime.now();
      _timestamps.removeWhere((t) => now.difference(t).inSeconds >= 1);
      if (_timestamps.length >= maxPerSecond) {
        throw StateError('Rate limit: $maxPerSecond calls/sec exceeded');
      }
      _timestamps.add(now);
    }
    return next(name, args);
  }
}
```

Infrastructure calls (`__role__="infra"`) pass through unchecked. Agent
tool calls that exceed the limit get a Python `RuntimeError`.

### Example: Grounding

Validate tool outputs against domain constraints before returning
results to the LLM. This is the primary motivation for middleware --
a single chokepoint where you can assert invariants on what data
flows back into the agent's context.

```dart
class GroundingMiddleware extends BridgeMiddleware {
  GroundingMiddleware({required this.validators});

  /// Function name -> output validator. Return true to pass.
  final Map<String, bool Function(Object?)> validators;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    final result = await next(name, args);
    final validate = validators[name];
    if (validate != null && !validate(result)) {
      throw StateError(
        'Grounding failed for "$name": output did not pass validation',
      );
    }
    return result;
  }
}
```

Usage:

```dart
bridge.use(GroundingMiddleware(validators: {
  'df_filter': (r) => r is int,                      // Must return a handle
  'fetch': (r) => r is Map && r['status'] == 200,    // Must succeed
}));
```

### Example: Access Control

Deny specific functions based on a permission set:

```dart
class AccessControlMiddleware extends BridgeMiddleware {
  AccessControlMiddleware({required this.denied});

  final Set<String> denied;

  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    if (role is ToolCall && denied.contains(name)) {
      throw StateError('Access denied: "$name" is not permitted');
    }
    return next(name, args);
  }
}
```

### Example: Argument Normalization

Middleware can mutate arguments before dispatch and transform results
on the way back -- the full bidirectional power of the onion model:

```dart
class NormalizerMiddleware extends BridgeMiddleware {
  @override
  Future<Object?> handle(
    String name,
    Map<String, Object?> args,
    CallRole role,
    ToolHandler next,
  ) async {
    // Normalize args: trim all string values before dispatch.
    final cleaned = {
      for (final e in args.entries)
        e.key: e.value is String ? (e.value as String).trim() : e.value,
    };
    final result = await next(name, cleaned);

    // Redact PII from string results on the way back.
    if (result is String) {
      return result.replaceAll(RegExp(r'\b\d{3}-\d{2}-\d{4}\b'), '[REDACTED]');
    }
    return result;
  }
}
```

## Registration

Register middleware on the bridge **before** attaching plugins:

```dart
final bridge = DefaultMontyBridge(platform: platform, log: logger);

// First registered = outermost in the chain.
bridge.use(GroundingMiddleware(validators: {...}));
bridge.use(TelemetryMiddleware());
bridge.use(RateLimitMiddleware(maxPerSecond: 10));

// Then attach plugins.
final registry = PluginRegistry();
registry.register(DataFramePlugin());
registry.register(WeatherPlugin());
await registry.attachTo(bridge);
```

Order matters. In this configuration:

1. **Grounding** (outermost) sees the final result and validates it.
2. **Telemetry** times the call including rate-limit overhead.
3. **Rate Limiter** (innermost) checks the limit just before dispatch.
4. **Handler** executes.

Results flow back outward: handler -> rate limiter -> telemetry -> grounding.

`use()` throws `StateError` if the bridge has been disposed. Middleware
registered after an `execute()` call takes effect on subsequent tool
calls within the same or later executions.

## Middleware State and Lifecycle

Middleware instances share the lifecycle of the bridge. State in a
middleware object (like `TelemetryMiddleware.durations` or
`RateLimitMiddleware._timestamps`) persists across multiple `execute()`
calls on the same bridge.

If you need per-execution state, reset it manually before each
`execute()` call, or create a new bridge per execution. In practice,
most applications create one bridge per session, so middleware state
is naturally scoped to the session.

## Middleware and Futures Batching

Both the synchronous and futures dispatch paths pass through the
middleware chain. When `useFutures: true` (the default) and the platform
implements `MontyFutureCapable`, multiple handler calls may be in-flight
concurrently. Each call gets its own independent pass through the
middleware chain.

This means middleware must be safe for concurrent use if futures batching
is active. The telemetry and rate limiter examples above are safe because
Dart is single-threaded (event loop) -- but if your middleware accesses
external resources (files, network, databases), ensure those resources
handle concurrent access.

For details on how futures batching works at the platform level, see
[Futures Batching](host-functions-advanced.md#futures-batching) in the
Advanced guide.

## Inter-Plugin Dependencies

Plugins sometimes need to call into each other. The recommended pattern
is **constructor injection** -- pass dependencies when you create the
plugin, before registration:

```dart
class BudgetPlugin extends MontyPlugin {
  BudgetPlugin({required this.memory});
  final MemoryPlugin memory;

  @override
  String get namespace => 'budget';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'budget_check',
        description: 'Check budget against stored limits.',
      ),
      handler: (args) async {
        return memory.recall(args['key'] as String);
      },
    ),
  ];
}

// Wire at creation time:
final memory = MemoryPlugin();
final budget = BudgetPlugin(memory: memory);
registry.register(memory);
registry.register(budget);
```

Constructor injection is:

- **Explicit** -- dependencies are visible in the constructor signature
- **Type-safe** -- no runtime resolution failures
- **Testable** -- pass mocks directly, no registry needed
- **Proxy-friendly** -- works with any object satisfying the interface

For **cross-cutting concerns** that would otherwise require many plugins
to know about each other (telemetry, grounding, rate limiting), use
`BridgeMiddleware` instead -- it operates at the dispatch chokepoint
without any plugin coupling.

### Historical note: CompositePlugin

An earlier version of `dart_monty_bridge` provided `CompositePlugin` and
`PluginRef<T>` for declaring inter-plugin dependencies with automatic
topological sort and cycle detection. This was removed in #197 because:

1. **Zero consumers** outside the test file used it. Constructor
   injection was already the established pattern.
2. **Type-identity conflicts.** `PluginRef<T>` uses runtime `is T`
   matching, which fails with proxied or cross-package plugin types.
3. **Unnecessary complexity.** ~180 lines of topological sort for a
   problem constructor injection solves in zero lines.

## Registry Error Handling

`PluginRegistry.attachTo()` and `disposeAll()` are resilient: they
process **all** plugins even if individual `onRegister` or `onDispose`
hooks throw. Errors are collected and thrown as a single `StateError`
after all plugins have been processed. This prevents one failing plugin
from blocking the rest.

## Complete Lifecycle

```text
1. Create bridge:   DefaultMontyBridge(platform: platform, log: logger)
2. Register MW:     bridge.use(grounding), bridge.use(telemetry)
3. Build registry:  registry.register(pluginA), registry.register(pluginB)
4. Attach:          registry.attachTo(bridge)  // wires functions + onRegister
5. Execute:         bridge.execute(code)       // MW wraps every tool call
6. Dispose:         registry.disposeAll()      // reverse registration order
                    bridge.dispose()
```

## Example: Per-Session Integration

A typical application creates one bridge per session. Middleware slots
into the setup path before plugins are attached:

```dart
final bridge = DefaultMontyBridge(platform: platform, log: logger);
bridge.use(SessionTelemetryMiddleware(sessionId: session.id));
bridge.use(GroundingMiddleware(validators: roomValidators));

final registry = PluginRegistry();
registry.register(DataFramePlugin(store: dfStore));
registry.register(AgentPlugin(runtime: runtime));
await registry.attachTo(bridge);
```

Each session gets its own bridge and middleware instances, so per-session
policy (rate limits, access control, telemetry) is naturally isolated
without shared state.
