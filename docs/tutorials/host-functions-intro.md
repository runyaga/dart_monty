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

[HostFunction](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/function.dart)
defines the handler, and
[HostContext](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/context.dart)
defines call capabilities.

## Host-function layers

Use a `MontyExtension` when several functions share attachment or disposal.
Use an OS handler when Python needs a namespace of filesystem or environment
operations. Use sub-execution when a suspended handler needs independent
Python work. See [Extension system](../deep-dives/extension-system.md),
[Nested execution](inputs-and-sub-scripts.md), and
[Failure propagation](../deep-dives/error-hierarchy.md).
