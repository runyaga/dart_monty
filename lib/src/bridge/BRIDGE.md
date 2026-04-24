# Bridge execution loop

## Happy-path flow

```
MontyRuntime.execute(code)
  │
  ├─ wraps ExecutionHandle(events: Stream<BridgeEvent>, result: Future<MontyResult>)
  │
  └─► PlatformBridge.execute(code)          [platform.dart]
        │
        ├─ emits BridgeRunStarted
        │
        └─► _run(code) ─── loop ────────────────────────────────────────┐
              │                                                           │
              ├─► platform.start(code, externalFunctions: [...])         │
              │     └── yields MontyProgress variant ──────────────────► │
              │                                                           │
              │   ┌── switch (progress) ◄────────────────────────────────┘
              │   │
              │   ├── MontyPending  (host function call)
              │   │     └─► HostDispatch.handlePending(pending)          [dispatch.dart]
              │   │               │
              │   │               ├── FFI  → dispatchToolCall()
              │   │               │             validate args
              │   │               │             await handler(args, ctx)
              │   │               │             platform.resume(result)  ──► loop
              │   │               │
              │   │               └── WASM → dispatchToolCallAsFuture()
              │   │                             validate args
              │   │                             launch handler future
              │   │                             platform.resumeAsFuture() ► loop
              │   │
              │   ├── MontyOsCall  (filesystem / OS operation)
              │   │     └─► _handleOsCall(osCall)                        [platform.dart]
              │   │               OsCallHandler(op, args, kwargs)
              │   │               platform.resume(result)  ──────────────► loop
              │   │
              │   ├── MontyResolveFutures  (WASM: collect deferred results)
              │   │     └─► HostDispatch.resolveFutures(resolve)
              │   │               await each _pendingFuture
              │   │               platform.resolveFutures(results, errors) ► loop
              │   │
              │   ├── MontyNameLookup  (Python name resolution)
              │   │     └─► platform.resumeNameLookupUndefined(name)  ──► loop
              │   │
              │   └── MontyComplete  (terminal)
              │         emit BridgeRunFinished / BridgeRunError
              │         return  (closes controller → ExecutionHandle.result completes)
              │
              └── on error: _emitScriptError / _emitMontyError / _emitInfraError
```

## Resume paths

| Method | Owner | When |
|---|---|---|
| `platform.resume(value)` | `HostDispatch`, `_handleOsCall` | Normal handler/OS result |
| `platform.resumeWithError(msg)` | `HostDispatch`, `_handleOsCall` | Handler threw or unknown function |
| `platform.resumeAsFuture()` | `HostDispatch` (WASM only) | Deferred tool call enqueued |
| `platform.resolveFutures(results, errors)` | `HostDispatch` (WASM only) | Batch-resolving deferred futures |
| `platform.resumeNameLookupUndefined(name)` | `PlatformBridge._run` | Python name not found in bridge |

## Seam: what goes where

**Add new dispatch logic → `HostDispatch` (`dispatch.dart`)**
- New tool routing rules
- New argument validation
- New future-tracking strategies
- The interceptor chain

**Add new loop behavior → `PlatformBridge._run` (`platform.dart`)**
- New `MontyProgress` variant handling
- Stream wrapper injection (`addStreamWrapper`)
- OS handler swapping (`setOsHandler`)

These classes are tightly coupled by design: `PlatformBridge` owns the loop
and owns OS dispatch; `HostDispatch` owns function registration and tool
dispatch. They share the same `MontyPlatform` and `BridgeLogger` instances.
Neither is independently testable today.

## Extension entry points

Extensions interact with the bridge via `AttachContext` (implemented by
`PlatformBridge`):
- `context.register(fn)` — adds a host function to `HostDispatch`
- `context.registerOs(handler)` — installs the OS call handler
- `context.addStreamWrapper(wrap)` — wraps the `execute` event stream

`MontyRuntimeExtension` (planned, `monty-client-bridge.md`) will consume
`MontyRuntime.coordinator` (the `ExtensionCoordinator`) to subscribe to inner
extension state without needing direct bridge access.
