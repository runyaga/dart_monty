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

## Host modules

The facade exports `ExternalModule`, `Monty`, and `MontyRuntime`. An
`ExternalModule` gives Python an importable module of host attributes,
including values, callables, and nested modules. Its constructor makes a
shallow copy of the attributes; names starting with `_` are protected.
Optional `stubs` supplies `.pyi` source for type checking. Pass modules through
`externalModules`, not as ordinary execution inputs.

`Monty.checkout(externalModules:)` and `Monty.withSession(externalModules:)`
accept a map from module names to `ExternalModule` values or zero-argument
factories returning modules. A factory may return a future. Core reads the
map live; successful factory results are cached for the session, and failed
factories can be retried by the next request.

`MontyRuntime.start(externalModules:)` supplies the map to root sessions:
the shared session, fresh sessions with `sandbox: true`, and replacement
sessions after state clearing or session loss. `HostContext.subExecute`
receives no modules. Sandbox children receive only
`SandboxExtension.childExternalModules`; they never inherit the parent
runtime's map. The child map accepts the same module values and factories,
and defaults to no modules.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start(
    externalModules: {'settings': ExternalModule({'answer': 42})},
  );
  try {
    final result = await runtime
        .execute('import settings\nsettings.answer')
        .result;
    assert(result.dartValue == 42, 'The module supplies its answer');
  } finally {
    await runtime.dispose();
  }
}
```

See core's [ExternalModule API comments](https://github.com/runyaga/dart_monty_core/blob/bcfbc232ece6436c3e68ec7edfca7c1cad6a32be/lib/src/platform/monty_value_structured.dart#L497),
[checkout and withSession API comments](https://github.com/runyaga/dart_monty_core/blob/bcfbc232ece6436c3e68ec7edfca7c1cad6a32be/lib/src/worker/monty.dart#L105),
and [module divergence and dispatch rules](https://github.com/runyaga/dart_monty_core/blob/bcfbc232ece6436c3e68ec7edfca7c1cad6a32be/docs/reference/upstream-divergences.md#external-modules-the-dart-model).
