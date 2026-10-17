# Host Functions

This guide covers parameter schemas, typed arguments, errors, and execution
events.

**Prerequisites:** Read the [Intro guide](host-functions-intro.md).

## HostFunctionSchema

Every host function has a schema with a name, optional description, and
parameters.

```dart
import 'package:dart_monty/dart_monty.dart';

const fetchDataSchema = HostFunctionSchema(
  name: 'fetch_data',
  description: 'Fetches data for a URL.',
  params: [
    HostParam(name: 'url', type: HostParamType.string),
    HostParam(
      name: 'timeout',
      type: HostParamType.integer,
      isRequired: false,
      defaultValue: MontyInt(30),
      description: 'Timeout in seconds.',
    ),
  ],
);
```

`HostFunctionSchema.toJsonSchema()` exposes the parameter declaration as a
JSON Schema object for code that discovers host functions.

## HostParam

Each `HostParam` has these fields.

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | `String` | required | Key in the handler argument map |
| `type` | `HostParamType` | required | Expected value kind |
| `isRequired` | `bool` | `true` | Whether an argument is required |
| `description` | `String?` | `null` | Schema description |
| `defaultValue` | `MontyValue?` | `null` | Value for an omitted optional argument |
| `jsonSchemaOverride` | `Map<String, Object?>?` | `null` | Schema for a complex parameter |

Parameters map positional and keyword Python arguments to the parameter names
in declaration order. An unknown argument, a missing required argument, or a
value with the wrong `HostParamType` raises Python `RuntimeError` before the
handler runs.

## HostParamType

Handlers receive `Map<String, MontyValue>` and return `Future<MontyValue>`.

| `HostParamType` | Value type |
|---|---|
| `string` | `MontyString` |
| `integer` | `MontyInt` or `MontyBigInt` |
| `number` | `MontyInt`, `MontyBigInt`, or `MontyFloat` |
| `boolean` | `MontyBool` |
| `list` | `MontyList` |
| `map` | `MontyDict` |
| `any` | Any `MontyValue` |

Validation preserves the supplied value. Optional parameters receive their
`defaultValue`, or `MontyNone` when no default is supplied. An explicit Python
`None` is a `MontyNone` value.

## Error Handling in Handlers

Throw `ExternalException` to select the Python exception type. Other handler
failures reach Python as `RuntimeError`.

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyBigInt;

final divide = HostFunction(
  schema: const HostFunctionSchema(
    name: 'divide',
    params: [
      HostParam(name: 'a', type: HostParamType.integer),
      HostParam(name: 'b', type: HostParamType.integer),
    ],
  ),
  handler: (args, _) async {
    final a = _integerAsDouble(args['a']!);
    final b = _integerAsDouble(args['b']!);
    if (b == 0) {
      throw const ExternalException('ValueError', 'Division by zero');
    }
    return MontyFloat(a / b);
  },
);

double _integerAsDouble(MontyValue value) => switch (value) {
  MontyInt(:final value) => value.toDouble(),
  MontyBigInt(:final value) => value.toDouble(),
  _ => throw ArgumentError.value(value),
};
```

## The BridgeEvent Stream

`MontyRuntime.events` emits runtime events. Each `execute` call also returns
an `ExecutionHandle` with an event stream for that execution.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> printEvents(MontyRuntime runtime) async {
  final handle = runtime.execute('greet("World")');
  final eventsDone = () async {
    await for (final event in handle.events) {
      switch (event) {
        case BridgeFunctionCallStart(:final name):
          print('Calling $name');
        case BridgeFunctionCallResult(:final result):
          print('Result: $result');
        case BridgeRunError(:final message):
          print('Error: $message');
        default:
          break;
      }
    }
  }();
  await Future.wait<Object?>([eventsDone, handle.result]);
}
```

`BridgeRunFinished` contains the run identifier, result fields, and captured
`print` output. `BridgeRunError` contains an error message and an optional
`MontyError` exception. `BridgeFunctionCallStart`, `BridgeFunctionCallArgs`,
`BridgeFunctionCallEnd`, and `BridgeFunctionCallResult` describe a host call.

## JSON Schema Export

Use `jsonSchemaOverride` when the advertised schema needs nested properties,
enums, or item declarations. Runtime validation still follows `type`.

```dart
import 'package:dart_monty/dart_monty.dart';

const filters = HostParam(
  name: 'filters',
  type: HostParamType.map,
  jsonSchemaOverride: {
    'type': 'object',
    'properties': {
      'status': {'type': 'string', 'enum': ['active', 'archived']},
    },
  },
);
```

## Next Steps

The [Intermediate guide](host-functions-intermediate.md) covers extensions,
OS handlers, child policies, and `EventLoopExtension`.
