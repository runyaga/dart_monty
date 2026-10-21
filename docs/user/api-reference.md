# API selection

Use `MontyRuntime` when code needs registered Dart capabilities, extensions,
execution events, or state that persists between calls. Its session mode lets
the application choose persistent globals or independently scheduled calls.

Use core's `Monty` and `MontySession` directly when an application needs only
pool ownership and session feeds.

Use `HostFunction` for one Python-callable Dart capability and
`MontyExtension` when capabilities share attachment, child policy, OS-call
contributions, or disposal. Use `HostContext.subExecute` for nested Python
work so a suspended handler does not re-enter its bridge.

Use `OSAccess` for an in-memory namespace. Use native mounts only when Python
must access host-backed files and the deployment can include core's native
mount library.

The supported declarations are exported from
[dart_monty.dart](https://github.com/runyaga/dart_monty/blob/main/lib/dart_monty.dart).
[MontyRuntime](https://github.com/runyaga/dart_monty/blob/main/lib/src/runtime/runtime.dart),
[HostFunction](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/function.dart),
[MontyExtension](https://github.com/runyaga/dart_monty/blob/main/lib/src/extension/extension.dart),
and [BridgeEvent](https://github.com/runyaga/dart_monty/blob/main/lib/src/bridge/event.dart)
define runtime, capability, extension, and event behavior.

See [Runtime concurrency](../deep-dives/bridge-concurrency.md),
[Extension system](../deep-dives/extension-system.md), and
[Failure propagation](../deep-dives/error-hierarchy.md) for cross-call
guarantees.
