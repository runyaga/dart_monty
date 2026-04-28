# REPL — Stateful Interactive Execution

## Overview

The REPL provides stateful Python execution where variables, functions,
classes, and closures persist natively across calls. The REPL maintains
a persistent Rust heap — everything survives, including non-serialisable
objects.

## Three API Levels

### 1. MontyRepl — Low-Level

Direct access to `feedRun()` (run to completion) and
`feedStart()`/`resume()` (suspend at host function calls).

```dart
final repl = MontyRepl();

// Run to completion
final result = await repl.feedRun('x = 42');
final r2 = await repl.feedRun('x + 1');
print(r2.value); // MontyInt(43)

// Functions persist
await repl.feedRun('def double(n):\n    return n * 2');
final r3 = await repl.feedRun('double(21)');
print(r3.value); // MontyInt(42)

await repl.dispose();
```

### 2. ReplPlatform — Bridge Adapter

A 20-line adapter that plugs `MontyRepl` into `DefaultMontyBridge`.
This enables the full extension dispatch system — middleware, events,
schema validation — without changing any bridge code.

```dart
final repl = MontyRepl();
final platform = ReplPlatform(repl: repl);
final bridge = DefaultMontyBridge(platform: platform);

// Register host functions on the bridge
bridge.register(myHostFunction);

// Bridge uses repl's feedStart/resume internally
final events = bridge.execute(code);
```

You rarely use `ReplPlatform` directly — `MontyRuntime` wraps it.

### 3. MontyRuntime — High-Level with Extensions

The recommended API. Combines `MontyRepl` + `DefaultMontyBridge` +
extension dispatch. All registered extensions work automatically.

```dart
final session = MontyRuntime(
  extensions: [
    JinjaTemplateExtension(),
    MessageBusExtension(),
    SandboxExtension(
      platformFactory: () async => createPlatformMonty(),
    ),
  ],
);

// Python calls tmpl_render() -> real Dart Jinja engine
final r = await session.execute(
  "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
).result;
print(r.value); // MontyString('Hello World!')

// State persists — x is still 42
await session.execute('x = 42').result;
final r2 = await session.execute('x + 1').result;
print(r2.value); // MontyInt(43)

// Event stream for real-time visibility
final events = session.execute('tmpl_render(...)');
await for (final event in events) {
  // BridgeToolCallStart, BridgeToolCallResult, etc.
}

await session.dispose();
```

## Continuation Detection

The REPL can detect whether a source fragment is syntactically
complete or needs more input — useful for building REPL UIs.

```dart
final mode = await repl.detectContinuation('def f():');
// ReplContinuationMode.incompleteBlock — needs trailing blank line

final mode2 = await repl.detectContinuation('x = (1 +');
// ReplContinuationMode.incompleteImplicit — unclosed paren

final mode3 = await repl.detectContinuation('x = 1');
// ReplContinuationMode.complete — ready to execute
```

This maps to the `>>>` vs `...` prompt pattern in CPython's
interactive interpreter.

## Host Function Dispatch

When Python calls a registered host function, the REPL suspends
and returns `MontyPending` with the function name, arguments,
and keyword arguments. The host resolves the call and resumes.

```dart
final progress = await repl.feedStart(
  'result = fetch("https://example.com")',
  externalFunctions: ['fetch'],
);

if (progress is MontyPending) {
  print(progress.functionName); // 'fetch'
  print(progress.arguments);    // [MontyString('https://...')]

  // Resolve and resume
  final done = await repl.resume('response body');
}
```

With `MontyRuntime`, this dispatch happens automatically through
the extension system — you never call `feedStart`/`resume` directly.

## help() Function

The bridge provides a built-in `help()` host function that queries
live bridge state — functions registered after initialization are
visible. Results are organized by extension category.

```python
>>> help()
# Returns JSON listing all functions by extension category:
# {"tools": {"tmpl": [{"name": "tmpl_render", ...}],
#            "msg": [{"name": "msg_send", ...}, ...],
#            "sandbox": [{"name": "sandbox_spawn", ...}, ...]}}

>>> help('tmpl_render')
# Returns schema detail:
# {"name": "tmpl_render",
#  "description": "Render a Jinja2 template...",
#  "params": [{"name": "template", "type": "string", ...}, ...]}

>>> help('render')
# Bare name — auto-disambiguates if unique, lists candidates if not
```

The introspection is **live** — functions registered after bridge
initialization (e.g. `EventLoopExtension`'s `el_recv`) are
visible in `help()` without restarting.

## Platform Support

The REPL works on both FFI (native) and WASM (browser):

- **FFI**: Full support including `SandboxExtension` with grandchildren
- **WASM**: Full support for `MontyRepl`, `MontyRuntime`, template
  and message bus extensions. Sandbox support requires multi-session
  Workers (see issue #280)

## Comparison with `Monty` / `Monty.exec`

**`Monty(code)` and `Monty.exec`** run in a fresh interpreter every call —
state from earlier calls does not persist. Use them for one-shot or
parameterised re-runs of the same program.

**`MontyRepl`** maintains a native Rust heap across calls:

- Functions, classes, closures persist
- All heap objects survive across calls
- Continuation detection for REPL UIs
- Direct `feedStart`/`resume` for host function dispatch
