# Host Functions

Host functions let Python code running in Monty call Dart handlers. A host
function has a `HostFunctionSchema` and a handler. The schema declares the
function name and its parameters. The handler receives validated
`MontyValue` arguments and returns a `MontyValue`.

## Why Host Functions Exist

Monty code receives application capabilities only through the functions and OS
handlers that the runtime registers. A host function defines one named,
typed Dart operation for Python code.

## Minimal Example

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start();
  try {
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'greet',
          description: 'Returns a greeting for a name.',
          params: [HostParam(name: 'name', type: HostParamType.string)],
        ),
        handler: (args, context) async {
          final name = (args['name']! as MontyString).value;
          context.emitText('Greeting $name');
          return MontyString('Hello, $name!');
        },
      ),
    );

    final result = await runtime.execute('greet("World")').result;
    print((result as MontyString).value);
  } finally {
    await runtime.dispose();
  }
}
```

`MontyRuntime.start` creates the runtime. Supplied extensions attach when
`execute` or `invoke` first uses the runtime. `register` adds a function to
that runtime. `execute` returns an
`ExecutionHandle`, whose `result` completes with the Python expression's
`MontyValue`.

## How It Works

The handler signature is `Future<MontyValue> Function(Map<String,
MontyValue>, HostContext)`. Read each value through its concrete type, such as
`MontyString`, `MontyInt`, or `MontyDict`.

## Next Steps

The [Beginner guide](host-functions-beginner.md) covers schemas, validation,
errors, and execution events.
