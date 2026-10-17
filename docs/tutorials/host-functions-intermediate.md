# Host Functions

This guide covers extensions, OS handlers, child policies, and
`EventLoopExtension`.

**Prerequisites:** Read the [Beginner guide](host-functions-beginner.md).

## MontyExtension

`MontyExtension` groups related `HostFunction` values. An extension declares a
namespace, its functions, optional OS handler contributions, and lifecycle
hooks. Pass extension instances to `MontyRuntime.start`.

```dart
import 'package:dart_monty/dart_monty.dart';

class StorageExtension extends MontyExtension {
  final Map<String, MontyValue> _store = {};

  @override
  String get namespace => 'storage';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'storage_get',
        params: [HostParam(name: 'key', type: HostParamType.string)],
      ),
      handler: (args, _) async {
        final key = (args['key']! as MontyString).value;
        return _store[key] ?? const MontyNone();
      },
    ),
  ];
}

Future<void> main() async {
  final runtime = await MontyRuntime.start(
    extensions: [StorageExtension()],
  );
  try {
    await runtime.execute('storage_get("theme")').result;
  } finally {
    await runtime.dispose();
  }
}
```

`onAttach(AttachContext)` runs while the extension attaches. It can register
OS handlers through `AttachContext.registerOs`. `onDispose()` runs when the
runtime disposes. Extensions with equal priority attach in registration order.

## OS Contributions

An `OsHandler` receives an operation name, positional `MontyValue` arguments,
and keyword `MontyValue` arguments. Return a `MontyValue`. Throw
`ExternalException` to raise a selected Python exception type.

```dart
import 'package:dart_monty/dart_monty.dart';

MontyValue readOnlyPath(
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  if (name == 'open' && args.length > 1 && args[1].dartValue != 'r') {
    throw const ExternalException('PermissionError', 'Read-only data');
  }
  throw const OsCallNotHandledException();
}

Future<void> main() async {
  final runtime = await MontyRuntime.start(
    osHandlers: {'Path.': readOnlyPath},
  );
  await runtime.dispose();
}
```

Use `OSAccess().call` as a memory-backed handler for `Path.` operations.
`MontyRuntime.start` accepts `os` for one handler and `osHandlers` for a
prefix map.

## Child Policies

`ChildPolicy.exclude` keeps an extension out of child sandboxes.
`ChildPolicy.inherit` shares its instance. `ChildPolicy.clone` creates a fresh
instance through `createChildInstance(ChildSpawnContext)`. `SandboxExtension`
creates child sandboxes when its Python functions request them.

## EventLoopExtension

`EventLoopExtension` supports a cooperative exchange. Python calls
`el_emit(value)` to publish a `MontyDict` and calls `el_recv()` to wait for an
event. Dart reads `lastEmitted` or `lastEmittedSignal` and supplies an event
through `dispatch`.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final events = EventLoopExtension();
  final runtime = await MontyRuntime.start(extensions: [events]);
  try {
    final handle = runtime.execute('''
el_emit({'status': 'ready'})
event = el_recv()
event['action']
''');
    while (!events.isWaiting) {
      await Future<void>.delayed(Duration.zero);
    }
    events.dispatch(
      const MontyDict([(MontyString('action'), MontyString('quit'))]),
    );
    await handle.result;
  } finally {
    await runtime.dispose();
  }
}
```

## HostContext

Handlers receive `HostContext` as their second argument. `executionId`
identifies the execution. `cancelToken` signals cancellation. `emitText`
adds text to the execution event stream. `os` exposes the registered
`OsHandler`, `parent` exposes child-event forwarding and schemas, and
`subExecute` runs a separate Python execution when the runtime provides it.

## Next Steps

The [Advanced guide](host-functions-advanced.md) covers `SandboxExtension`
and larger host-function designs.
