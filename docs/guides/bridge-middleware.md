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

Python signals the role via a reserved `__role__` kwarg:

```python
# Infrastructure call -- middleware observes only
result = list_functions(__role__="infra")

# Tool call (default when __role__ is omitted)
data = df_create(data=rows)
```

The bridge strips `__role__` before dispatching to the handler -- plugins
never see it. When omitted, the default is `ToolCall`.

### Why sealed?

Adding a new `CallRole` subtype is a **compile-time breaking change**.
Every `switch (role)` in every middleware must handle the new case. Policy
gaps are caught at build time, not in production.

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
2. **Throw to reject.** The exception surfaces as a Python `RuntimeError`.
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
  'df_filter': (r) => r is int,               // Must return a handle
  'fetch': (r) => (r as Map)['status'] == 200, // Must succeed
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

`use()` throws `StateError` if the bridge has been disposed. You can
register middleware at any point before or after `execute()`, but
registration during execution is undefined behaviour.

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

## Why CompositePlugin Was Removed

Prior to the middleware addition, `CompositePlugin` and `PluginRef<T>`
provided inter-plugin dependency resolution with topological sort and
cycle detection. They were removed in #197 for three reasons:

### 1. Zero consumers

No plugin outside the test file used `CompositePlugin`. The established
pattern is constructor injection -- pass dependencies when you create
the plugin, before registration:

```dart
// CompositePlugin (removed) -- implicit, resolved at attachTo()
class BudgetPlugin extends MontyPlugin with CompositePlugin {
  final memoryRef = PluginRef<MemoryPlugin>();

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [memoryRef];

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: HostFunctionSchema(name: 'budget_check', description: '...'),
      handler: (args) async {
        final mem = memoryRef.plugin; // resolved at attachTo()
        return mem.recall(args['key'] as String);
      },
    ),
  ];
}

// Constructor injection (current) -- explicit, resolved at creation
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
        description: '...',
      ),
      handler: (args) async {
        return memory.recall(args['key'] as String);
      },
    ),
  ];
}
```

Constructor injection is explicit about dependencies, type-safe at
compile time, and trivially testable with mocks.

### 2. Type-identity conflicts

`PluginRef<T>` resolves via `candidate is T` at runtime. This fails when:

- The same plugin type exists in multiple packages (different type
  identity despite identical source).
- A plugin is wrapped in a proxy or adapter (the proxy is not `T`).
- The incoming `MontyPluginProxy` pattern (dart_claw#3) wraps remote
  plugins for cross-process bridging -- `PluginRef` would never match.

### 3. Unnecessary complexity

Topological sort, cycle detection, and lazy resolution added ~180 lines
of code for a problem constructor injection solves in zero lines.
Removing it simplified `PluginRegistry.attachTo()` from a multi-phase
dependency resolver to a straightforward registration-order loop.

### What replaces inter-plugin communication?

**Constructor injection** for compile-time dependencies (the common case).
**BridgeMiddleware** for cross-cutting concerns that would otherwise
require plugins to know about each other (the middleware case).

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

## Integration with Soliplex

In Soliplex, the bridge is created per-session inside
`MontyScriptEnvironment`. Middleware slots into the setup path before
plugins are attached:

```dart
final bridge = DefaultMontyBridge(platform: platform, log: logger);
bridge.use(SessionTelemetryMiddleware(sessionId: session.id));
bridge.use(GroundingMiddleware(validators: roomValidators));

final registry = PluginRegistry();
registry.register(DataFramePlugin(store: dfStore));
registry.register(AgentPlugin(runtime: runtime));
await registry.attachTo(bridge);
```

Each session gets its own middleware instances, so per-session policy
(rate limits, access control, telemetry) is isolated without shared state.
