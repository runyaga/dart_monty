# Host Functions

Host functions let Python code running inside Monty call Dart code. This is the core integration pattern: Python calls a function, Monty pauses, Dart runs your handler, and the result flows back into Python.

## Quick Example

```dart
bridge.register(HostFunction(
  schema: const HostFunctionSchema(
    name: 'greet',
    description: 'Returns a greeting.',
    params: [HostParam(name: 'name', type: HostParamType.string)],
  ),
  handler: (args) async => 'Hello, ${args['name']}!',
));

await bridge.execute('greet("World")').last; 
```

## Core Concepts

### Schemas and Parameters
Every function requires a `HostFunctionSchema`. This defines the name, description, and parameters. Typed parameters enable automatic validation and coercion:

- **Types**: `string`, `integer`, `float`, `boolean`, `map`, `list`, `any`.
- **Validation**: Monty ensures Python passes the correct types before your handler is even called.

### Bridge Events
`bridge.execute()` returns a `Stream<BridgeEvent>`, allowing you to observe execution in real-time:
- `BridgeRunStarted`: Execution begins.
- `BridgePrintReceived`: Python called `print()`.
- `BridgeFunctionCalling`: A host function is about to be called.
- `BridgeFunctionCompleted`: A host function returned.
- `BridgeRunFinished`: Final result and output.

### Plugins and Namespaces
For larger projects, group functions into `MontyPlugin` classes. Use namespaces to avoid collisions:

```dart
class MathPlugin extends MontyPlugin {
  @override
  String get namespace => 'math';

  @override
  List<HostFunction> get functions => [ ... ];
}

bridge.register(MathPlugin()); // Functions available as math_add(), math_sub(), etc.
```

## Advanced Patterns

### Middleware
Use `BridgeMiddleware` to intercept all calls. Common uses include:
- **Logging/Telemetry**: Track tool usage.
- **Grounding**: Inject context before a call.
- **Access Control**: Block certain calls based on state.

### Async Handlers
All handlers are `async`. You can perform network requests, database queries, or wait for user input before returning a value to Python.

### The Event Loop
The `EventLoopBridge` (provided by `dart_monty_bridge`) is designed for long-running sessions where Python and Dart communicate bidirectionally via events.
