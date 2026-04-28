# Host Functions -- Beginner

This guide covers typed parameter schemas, argument validation and
coercion, error handling in handlers, and the `BridgeEvent` stream.

**Prerequisites:** Read the [Intro guide](host-functions-intro.md) first.

## HostFunctionSchema

Every host function has a schema that declares its name, description,
and parameters:

```dart
const schema = HostFunctionSchema(
  name: 'fetch_data',
  description: 'Fetch JSON data from a URL.',
  params: [
    HostParam(name: 'url', type: HostParamType.string),
    HostParam(
      name: 'timeout',
      type: HostParamType.integer,
      isRequired: false,
      defaultValue: 30,
      description: 'Request timeout in seconds.',
    ),
  ],
);
```

The schema serves two purposes:

1. **Runtime validation** -- the bridge validates and coerces arguments
   before calling your handler. If Python passes wrong types, the bridge
   raises a `FormatException` back to Python before your code runs.
2. **JSON Schema export** -- `schema.toJsonSchema()` produces a standard
   JSON Schema object for tool discovery (e.g., MCP integration).

## HostParam

Each parameter is defined with `HostParam`:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `String` | required | Parameter name (key in the args map) |
| `type` | `HostParamType` | required | Expected type |
| `isRequired` | `bool` | `true` | Whether the caller must supply a value |
| `description` | `String?` | `null` | Human-readable description for JSON Schema |
| `defaultValue` | `Object?` | `null` | Value used when argument is absent and not required |
| `jsonSchemaOverride` | `Map<String, Object?>?` | `null` | Full JSON Schema override for complex types |

## HostParamType

The type system maps Python types to Dart types with automatic coercion:

| `HostParamType` | Python type | Dart type | Coercion |
|-----------------|-------------|-----------|----------|
| `string` | `str` | `String` | Exact match only |
| `integer` | `int` | `int` | Accepts `num` (truncates) and numeric `String` |
| `number` | `float` | `num` | Accepts `int`, `double`, and numeric `String` |
| `boolean` | `bool` | `bool` | Exact match only |
| `list` | `list` | `List<Object?>` | Exact match only |
| `map` | `dict` | `Map<String, Object?>` | Exact match only |
| `any` | any | `Object?` | Passes through without type checking |

The `integer` and `number` types perform smart coercion. If Python sends
a float where you declared `integer`, the bridge truncates it to `int`.
If Python sends a numeric string, the bridge parses it. All other types
require exact matches.

## Argument Mapping

When Python calls a host function, Monty provides positional arguments
and optional keyword arguments. The schema's `mapAndValidate()` method
maps them to a named parameter map:

```text
Python: fetch_data("https://example.com", timeout=10)
  positional: ["https://example.com"]
  kwargs: {"timeout": 10}

Schema maps to: {"url": "https://example.com", "timeout": 10}
```

**Rules:**

- Positional arguments are matched to `params` by declaration order.
- Keyword arguments overlay by name.
- Extra positional arguments beyond the declared params raise a
  `FormatException`.
- Unknown keyword argument names raise a `FormatException`.
- Missing required parameters raise a `FormatException`.
- Absent optional parameters receive their `defaultValue`.

## Error Handling in Handlers

When your handler throws, the bridge catches the exception and sends it
back to Python as a runtime error via `resumeWithError()`. Python sees a
standard exception.

```dart
HostFunction(
  schema: const HostFunctionSchema(
    name: 'divide',
    description: 'Divide two numbers.',
    params: [
      HostParam(name: 'a', type: HostParamType.number),
      HostParam(name: 'b', type: HostParamType.number),
    ],
  ),
  handler: (args) async {
    final a = args['a'] as num;
    final b = args['b'] as num;
    if (b == 0) throw ArgumentError('Division by zero');
    return a / b;
  },
)
```

If Python calls `divide(10, 0)`, it gets a Python exception with the
message `"Division by zero"`. The bridge logs the error with stack trace
via `struct_log` and emits a `BridgeToolCallResult` with the error
message.

You do not need to catch exceptions yourself for error propagation --
the bridge does it automatically. Only catch if you need custom recovery.

## The BridgeEvent Stream

`bridge.execute()` returns a `Stream<BridgeEvent>`. The events form a
sealed class hierarchy declared in
`lib/src/bridge/event.dart`. **Use the class names below verbatim** —
the table is generated against the real source, not aspirational
naming.

### Lifecycle Events

| Event | When | Key fields |
|-------|------|------------|
| `BridgeRunStarted` | Execution begins | `threadId`, `runId` |
| `BridgeRunFinished` | Execution completes | `threadId`, `runId`, `value`, `montyValue`, `printOutput` |
| `BridgeRunError` | Execution fails | `message`, `printOutput`, `exception` |

> **Print output lives on `BridgeRunFinished.printOutput`** (and on
> `BridgeRunError.printOutput` when an error interrupts execution).
> There are no per-event text classes — `print()` calls are buffered
> and surfaced once at the end as a single `String?`. If you need
> incremental text from a host handler mid-call, see
> `BridgeFunctionEmit` below.

### Host Function Call Events

Each host function invocation emits a sequence of events:

```text
BridgeCallStarted(callId: "0")
BridgeFunctionCallStart(callId: "0", name: "greet")
BridgeFunctionCallArgs(callId: "0", delta: '{"name":"World"}')
BridgeFunctionCallEnd(callId: "0")
  -- handler runs (may emit BridgeFunctionEmit one or more times) --
BridgeFunctionCallResult(callId: "0", result: "Hello, World!")
BridgeCallFinished(callId: "0")
```

| Event | Description | Key fields |
|-------|-------------|------------|
| `BridgeCallStarted` | A host function call begins (wraps the call) | `callId` |
| `BridgeFunctionCallStart` | Function name resolved | `callId`, `name` |
| `BridgeFunctionCallArgs` | One JSON delta of the arguments stream | `callId`, `delta` |
| `BridgeFunctionCallEnd` | Arguments complete; handler about to run | `callId` |
| `BridgeFunctionEmit` | Handler emitted intermediate text via `HostContext.emit` (zero or more) | `callId`, `text` |
| `BridgeFunctionCallResult` | Handler result (or error string) | `callId`, `result` |
| `BridgeCallFinished` | Host function call complete (wraps the call) | `callId` |

### OS Call Events

Python access to `pathlib`, `os`, `datetime`, etc. flows through an
`OsCallHandler` you register on the runtime; each access emits an
`OsCall` event pair regardless of whether you registered a handler:

| Event | Description | Key fields |
|-------|-------------|------------|
| `BridgeOsCallStart` | Python triggered an OS-level operation | `callId`, `operationName`, `argumentSummary` |
| `BridgeOsCallResult` | Operation completed (or rejected if no handler registered) | `callId`, `result`, `durationMs` |

### Child Runtime Events

When `SandboxExtension` spawns child interpreters, the parent stream
re-emits each child's events wrapped in `BridgeChildEvent`:

| Event | Description | Key fields |
|-------|-------------|------------|
| `BridgeChildEvent` | An event from a child runtime, attributed to its origin | `childHandle`, `inner` |

`inner` is itself a `BridgeEvent` — pattern-match it the same way you
match top-level events.

### Listening to Events

Use pattern matching on the sealed class to handle events:

```dart
await for (final event in bridge.execute(code)) {
  switch (event) {
    case BridgeRunStarted(:final threadId, :final runId):
      print('Started: thread=$threadId run=$runId');
    case BridgeFunctionCallStart(:final callId, :final name):
      print('Calling: $name (call $callId)');
    case BridgeFunctionCallResult(:final callId, :final result):
      print('Result: $result (call $callId)');
    case BridgeFunctionEmit(:final callId, :final text):
      print('Mid-call text from $callId: $text');
    case BridgeRunFinished(:final value, :final printOutput):
      print('Done: value=$value output=$printOutput');
    case BridgeRunError(:final message, :final printOutput):
      print('Error: $message (output before error: $printOutput)');
    default:
      break;
  }
}
```

## JSON Schema Export

`HostFunctionSchema.toJsonSchema()` produces a standard JSON Schema
object compatible with MCP tool `inputSchema`:

```dart
final schema = HostFunctionSchema(
  name: 'search',
  description: 'Search by query.',
  params: [
    HostParam(name: 'query', type: HostParamType.string),
    HostParam(name: 'limit', type: HostParamType.integer, isRequired: false),
  ],
);

print(schema.toJsonSchema());
// {
//   "type": "object",
//   "properties": {
//     "query": {"type": "string"},
//     "limit": {"type": "integer"}
//   },
//   "required": ["query"]
// }
```

For complex schemas (nested objects, enums, array item types), use
`jsonSchemaOverride` on individual `HostParam`s:

```dart
HostParam(
  name: 'filters',
  type: HostParamType.map,
  jsonSchemaOverride: {
    'type': 'object',
    'properties': {
      'status': {'type': 'string', 'enum': ['active', 'archived']},
      'tags': {'type': 'array', 'items': {'type': 'string'}},
    },
  },
)
```

**Note:** `jsonSchemaOverride` controls only the schema advertised to
external consumers (e.g., LLMs via MCP). Runtime validation in
`validate()` still uses the `type` field. Ensure the override is
consistent with `type` to avoid mismatches.

## MontyBridge Configuration

`MontyBridge` accepts several constructor parameters:

```dart
MontyBridge(
  platform: createPlatformMonty(), // Required: MontyPlatform backend
  limits: MontyLimits(        // Optional: resource constraints
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
    stackDepth: 100,
  ),
  useFutures: true,           // Optional: enable futures batching (default: true)
  logger: myLogger,           // Optional: custom Logger instance
)
```

**Futures batching:** When `useFutures` is `true` and the platform
supports `MontyFutureCapable`, host function calls are dispatched as
futures and resolved in batches. This allows Python to issue multiple
host function calls that execute concurrently on the Dart side. When
`false`, each call blocks until its handler completes.

## Unregistering Functions

Functions can be removed at runtime:

```dart
bridge.register(myFunction);
// ...later...
bridge.unregister('my_function_name');
```

Both `register()` and `unregister()` throw `StateError` if the bridge
has been disposed.

## Next Steps

The [Intermediate guide](host-functions-intermediate.md) covers organizing
functions into extensions with `MontyExtension` and `ExtensionCoordinator`, namespace
validation, lifecycle hooks, introspection builtins, and the
`EventLoopExtension` for bidirectional Python/Dart communication.
