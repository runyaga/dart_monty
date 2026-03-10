# Host Functions

Host functions extend the Monty interpreter with Dart-implemented
capabilities. Each registration creates **two** call paths simultaneously:

1. **Python path** -- callable from within `monty_run` or `monty_session_exec`
   as a regular Python function (e.g. `result = add(a=3, b=4)`)
2. **MCP tool path** -- callable directly by the LLM as a standalone MCP tool,
   bypassing Python entirely

Understanding the difference between these paths is key to handling return
values and errors correctly.

> **Runnable examples:** See
> [`example/host_function.dart`](../example/host_function.dart) and
> [`example/plugin.dart`](../example/plugin.dart). These are tested in CI
> via `test/src/examples_test.dart`.

## Registering a single function

```dart
import 'package:dart_monty_mcp/dart_monty_mcp.dart';

final server = MontyMcpServer(platformFactory: createPlatform);

server.registerHostFunction(
  HostFunction(
    schema: HostFunctionSchema(
      name: 'add',
      description: 'Add two numbers',
      params: [
        HostParam(name: 'a', type: HostParamType.number),
        HostParam(name: 'b', type: HostParamType.number),
      ],
    ),
    handler: (args) async => (args['a']! as num) + (args['b']! as num),
  ),
);

await server.serve(transport);
```

## Registering a plugin (multiple functions)

```dart
server.registerPlugin(myPlugin);
```

`registerPlugin()` iterates the plugin's `functions` list and calls
`registerHostFunction()` for each one.

## Writing a MontyPlugin subclass

```dart
import 'package:dart_monty_mcp/dart_monty_mcp.dart';

class MathPlugin extends MontyPlugin {
  @override
  String get namespace => 'math';

  @override
  String? get systemPromptContext =>
      'Math functions: add(a, b), multiply(a, b)';

  @override
  List<HostFunction> get functions => [
        HostFunction(
          schema: HostFunctionSchema(
            name: 'add',
            description: 'Add two numbers',
            params: [
              HostParam(name: 'a', type: HostParamType.number),
              HostParam(name: 'b', type: HostParamType.number),
            ],
          ),
          handler: (args) async =>
              (args['a']! as num) + (args['b']! as num),
        ),
        HostFunction(
          schema: HostFunctionSchema(
            name: 'multiply',
            description: 'Multiply two numbers',
            params: [
              HostParam(name: 'a', type: HostParamType.number),
              HostParam(name: 'b', type: HostParamType.number),
            ],
          ),
          handler: (args) async =>
              (args['a']! as num) * (args['b']! as num),
        ),
      ];
}
```

Plugins also support lifecycle hooks: override `onRegister(MontyBridge)`
and `onDispose()` for setup/teardown logic.

## Parameter types

The `HostParamType` enum maps Dart types to JSON Schema types and Monty
Python types:

| HostParamType | Dart type | JSON Schema type | Python type |
|---------------|-----------|------------------|-------------|
| `string` | `String` | `string` | `str` |
| `integer` | `int` | `integer` | `int` |
| `number` | `num` | `number` | `float` |
| `boolean` | `bool` | `boolean` | `bool` |
| `list` | `List<Object?>` | `array` | `list` |
| `map` | `Map<String, Object?>` | `object` | `dict` |
| `any` | `Object?` | *(unconstrained)* | any |

The `integer` and `number` types perform coercion: numeric strings and
`num`/`int` cross-types are accepted and converted automatically.

## Optional parameters with defaults

```dart
HostParam(
  name: 'precision',
  type: HostParamType.integer,
  isRequired: false,
  defaultValue: 2,
  description: 'Decimal places to round to',
),
```

When `isRequired` is `false`:

- The parameter is omitted from the JSON Schema `required` array
- If the caller omits it, `validate()` returns `defaultValue`

## JSON Schema overrides

For complex schemas that `HostParamType` cannot express (nested objects,
enums, arrays with item types), use `jsonSchemaOverride`:

```dart
HostParam(
  name: 'filters',
  type: HostParamType.map,
  jsonSchemaOverride: {
    'type': 'object',
    'properties': {
      'status': {'type': 'string', 'enum': ['active', 'archived']},
      'limit': {'type': 'integer', 'minimum': 1},
    },
  },
),
```

The override controls only the schema advertised to LLMs via MCP. Runtime
validation still uses `type`, so ensure consistency between the two.

## Return values and error handling

Your `handler`'s return value and exceptions are treated differently
depending on how the function was called.

### MCP tool path (LLM calls directly)

When an LLM calls the function as a direct MCP tool:

- **Success**: The return value is **always stringified** via
  `'$result'` and wrapped in `TextContent`. A handler returning
  `[1, 2]` becomes the literal string `"[1, 2]"`.
- **Error**: If the handler throws, the exception is caught and returned
  as `CallToolResult(isError: true)` with `e.toString()` as the message.

### Python path (called from interpreter)

When the function is called from Python code:

- **Success**: The Dart return value is passed back to the Python
  interpreter. Complex types like `List` and `Map` become Python `list`
  and `dict` objects that Python code can interact with.
- **Error**: If the handler throws, the exception is converted to a
  Python-level error via `MontySession.resumeWithError()`. Python code
  can catch it with `try`/`except`.

### Positional-to-keyword mapping

When Python calls a host function with positional arguments (e.g.
`my_func(10, 'abc')`), the bridge maps them to keyword arguments based
on the order defined in the `HostFunctionSchema`'s `params` list. The
`mapAndValidate` method handles this, merging positional args with any
explicit keyword args from the Python call.

## Name restrictions

Function names **must not** start with `monty_`. This prefix is reserved for
the five [built-in tools](../README.md#tools). Attempting to register a
function with this prefix throws `ArgumentError`.

## Thread safety

Host function handlers may be called concurrently. Direct MCP tool calls
invoke the handler immediately (bypassing session locks), so multiple LLM
tool calls can hit the same handler in parallel. Plugin authors must ensure
handlers are safe for concurrent invocation.

Within a session, the B3 concurrency guard serializes `execute()` calls so
two `monty_session_exec` requests to the same session do not interleave.

## Dual-registration flow

```text
registerHostFunction(fn)
  |
  +---> MontySessionManager._hostFunctions.add(fn)
  |       (propagated to all future sessions via McpMontySession.register)
  |
  +---> McpServer.registerTool(fn.name, ...)
          (LLM can call fn directly as MCP tool)
```

When Python code calls a host function inside a session:

1. `MontySession.start()` yields a `MontyPending` with the function name
   and arguments
2. `McpMontySession._executeWithHostFunctions()` dispatches to the handler
3. The result is fed back via `MontySession.resume(result)`
4. The loop continues until `MontyComplete` is returned
