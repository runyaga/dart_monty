# Host Functions -- Intro

Host functions let Python code running inside Monty call Dart code.
This is the core integration pattern: Python calls a function name,
Monty pauses execution, Dart runs your handler, and the return value
flows back into Python.

## Why Host Functions Exist

Monty is a sandboxed Python interpreter. It cannot access files, the
network, or system APIs on its own. Host functions are the controlled
gateway: you decide exactly which capabilities Python gets by
registering named functions with the bridge.

From Python's perspective, host functions look like built-in globals.
No imports, no setup -- just call the function.

## Minimal Example

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

Future<void> main() async {
  final bridge = MontyBridge(platform: Monty());

  // Register a host function
  bridge.register(HostFunction(
    schema: const HostFunctionSchema(
      name: 'greet',
      description: 'Returns a greeting for the given name.',
      params: [
        HostParam(name: 'name', type: HostParamType.string),
      ],
    ),
    handler: (args) async {
      final name = args['name'] as String;
      return 'Hello, $name!';
    },
  ));

  // Execute Python that calls the host function
  await for (final event in bridge.execute('result = greet("World")')) {
    if (event is BridgeRunFinished) {
      print(event.printOutput); // null (no print() calls in the Python code)
      print(event.value);       // Hello, World!
    }
  }

  bridge.dispose();
}
```

## What Just Happened

1. `MontyBridge` wraps a `MontyPlatform` and manages the
   start/resume dispatch loop for you.
2. `bridge.register()` tells the bridge about a function named `greet`
   with one string parameter.
3. `bridge.execute()` runs the Python code. When Python calls `greet("World")`,
   the bridge pauses execution, calls your handler with
   `{'name': 'World'}`, and feeds the return value (`'Hello, World!'`)
   back to Python.
4. The returned `Stream<BridgeEvent>` emits lifecycle events. The final
   `BridgeRunFinished` carries the Python expression's return value.

## The Low-Level Protocol (Optional Context)

Under the hood, the bridge runs this loop against `MontyPlatform`:

```text
start(code, externalFunctions: ['greet'])
  -> MontyPending(functionName: 'greet', arguments: ['World'])
resume('Hello, World!')
  -> MontyComplete(result: ...)
```

`MontyBridge` automates this loop. You only need the raw protocol
if you are building a custom bridge. For normal usage, `register()` +
`execute()` is all you need.

## Next Steps

The [Beginner guide](host-functions-beginner.md) covers typed parameters,
argument validation, error handling, and the `BridgeEvent` stream in detail.
