# Host Functions -- Intro

Host functions let Python code running inside Monty call Dart code.
This is the core integration pattern: Python calls a function name,
Monty pauses execution, Dart runs your handler, and the return value
flows back into Python.

## Why Host Functions Exist

Monty is a sandboxed Python interpreter. It cannot access files, the
network, or system APIs on its own. Host functions are the controlled
gateway: you decide exactly which capabilities Python gets by
registering named functions with the runtime.

From Python's perspective, host functions look like built-in globals.
No imports, no setup -- just call the function.

## Minimal Example

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = MontyRuntime();

  // Register a host function
  runtime.register(HostFunction(
    schema: const HostFunctionSchema(
      name: 'greet',
      description: 'Returns a greeting for the given name.',
      params: [
        HostParam(name: 'name', type: HostParamType.string),
      ],
    ),
    handler: (args, ctx) async {
      final name = args['name'] as String;
      return 'Hello, $name!';
    },
  ));

  // Execute Python that calls the host function
  final handle = runtime.execute('greet("World")');
  final result = await handle.result;
  print(result.value); // Hello, World!

  await runtime.dispose();
}
```

## What Just Happened

1. `MontyRuntime` manages the execution session, tool registry, and
   bridge for you.
2. `runtime.register()` tells the runtime about a function named `greet`
   with one string parameter.
3. `runtime.execute()` runs the Python code. When Python calls `greet("World")`,
   execution pauses, Dart runs your handler with
   `{'name': 'World'}`, and feeds the return value (`'Hello, World!'`)
   back to Python.
4. The `ExecutionHandle` provides a `result` future that completes with
   the final return value of the Python expression.

## Next Steps

The [Beginner guide](host-functions-beginner.md) covers typed parameters,
argument validation, error handling, and the `BridgeEvent` stream in detail.
