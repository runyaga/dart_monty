# Host Functions -- Intro

Host functions let Python code running inside Monty call Dart code. This is the core integration pattern: Python calls a function name, Monty pauses execution, Dart runs your handler, and the return value flows back into Python.

## Why Host Functions Exist

Monty is a sandboxed Python interpreter. It cannot access files, the network, or system APIs on its own. Host functions are the controlled gateway: you decide exactly which capabilities Python gets by registering named functions with the bridge.

From Python's perspective, host functions look like built-in globals. No imports, no setup -- just call the function.

## Minimal Example with `AgentSession`

The recommended way to use host functions is via `AgentSession`. It handles the bridge, the event loop, and state persistence for you.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  // 1. Create a session
  final session = AgentSession();

  // 2. Register a host function
  session.register(HostFunction(
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

  // 3. Execute Python that calls the host function
  final result = await session.execute('greet("World")');
  print(result.value); // Hello, World!

  session.dispose();
}
```

## What Just Happened

1.  **`AgentSession`** provides a high-level API that combines the Python interpreter with a tool-calling bridge.
2.  **`session.register()`** tells the session about a function named `greet` with one string parameter.
3.  **`session.execute()`** runs the Python code. When Python calls `greet("World")`, the session pauses execution, calls your Dart handler with `{'name': 'World'}`, and feeds the return value (`'Hello, World!'`) back to Python.
4.  **Result Capture**: The final result of the Python script is returned as a `MontyResult`.

## The Low-Level Bridge (Optional)

Under the hood, `AgentSession` uses `MontyBridge`. If you need raw event streaming or custom middleware without the automatic state persistence of `AgentSession`, you can use the bridge directly:

```dart
final bridge = DefaultMontyBridge(platform: Monty().platform);
bridge.register(myFunction);
final eventStream = bridge.execute(code);
```

## Next Steps

The [Beginner guide](host-functions-beginner.md) covers typed parameters, argument validation, and error handling in detail.
