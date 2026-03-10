# dart_monty_mcp

MCP (Model Context Protocol) server that exposes the Monty sandboxed Python
interpreter as callable tools. An LLM can execute Python code, manage
persistent interpreter sessions, and call custom Dart host functions -- all
through the standard MCP tool protocol.

Monty is a restricted Python interpreter built in Rust
([pydantic/monty](https://github.com/pydantic/monty)). This package wraps it
in an MCP server so any MCP-compatible client (Claude Desktop, Cursor,
soliplex_tui, or your own application) can use Python as a tool.

## Tools

### Built-in tools

| Tool | Description |
|------|-------------|
| `monty_run` | Execute Python in a fresh interpreter (stateless, one-shot) |
| `monty_session_create` | Create a persistent Python session |
| `monty_session_exec` | Execute code in a persistent session (variables persist) |
| `monty_session_list` | List active sessions |
| `monty_session_destroy` | Destroy a session and free resources |

### Host function tools

Any Dart function registered via `registerHostFunction()` or
`registerPlugin()` also appears as an MCP tool. For example, registering a
function named `add` creates a sixth tool `add` that the LLM can call
directly. See [Host Functions](#host-functions) for details.

## Quick Start

### Claude Desktop / MCP Client

Add to your MCP client configuration (e.g.
`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "monty": {
      "command": "dart",
      "args": [
        "run",
        "packages/dart_monty_mcp/bin/dart_monty_mcp.dart",
        "--library-path",
        "/path/to/libdart_monty_native.dylib"
      ],
      "cwd": "/path/to/dart_monty"
    }
  }
}
```

You can omit `--library-path` if you set the `MONTY_LIBRARY_PATH` environment
variable instead.

### soliplex_tui

```bash
DART_MONTY_LIB_PATH=/path/to/libdart_monty_native.dylib \
  soliplex_tui \
  --llm-provider ollama --llm-model qwen3-coder \
  --mcp monty="/path/to/dart_monty_mcp_server.sh" \
  --verbose --json
```

### Programmatic usage

```dart
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

final server = MontyMcpServer(
  platformFactory: () => MontyFfi(
    bindings: NativeBindingsFfi(libraryPath: '/path/to/lib'),
  ),
);

// Stateless execution
final result = await server.sessionManager.executeStateless('2 + 2');
print(result.content.first); // TextContent(text: '4')

// Persistent session
server.sessionManager.createSession(id: 'calc');
final session = server.sessionManager.getSession('calc')!;
await session.execute('x = 42');
final r = await session.execute('x * 2'); // 84
await server.sessionManager.destroySession('calc');
```

## Host Functions

Host functions let you extend the interpreter with Dart-implemented
capabilities. Each registration creates **two** call paths simultaneously:

1. **Python path** -- callable from within `monty_run` or `monty_session_exec`
   as a regular Python function (e.g. `result = add(a=3, b=4)`)
2. **MCP tool path** -- callable directly by the LLM as a standalone MCP tool,
   bypassing Python entirely

### Registering a single function

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

### Registering a plugin (multiple functions)

```dart
server.registerPlugin(myPlugin);
```

`registerPlugin()` iterates the plugin's `functions` list and calls
`registerHostFunction()` for each one.

### Writing a MontyPlugin subclass

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

### Parameter types

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

### Optional parameters with defaults

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

### JSON Schema overrides

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

### Name restrictions

Function names **must not** start with `monty_`. This prefix is reserved for
the five built-in tools. Attempting to register a function with this prefix
throws `ArgumentError`.

### Thread safety

Host function handlers may be called concurrently. Direct MCP tool calls
invoke the handler immediately (bypassing session locks), so multiple LLM
tool calls can hit the same handler in parallel. Plugin authors must ensure
handlers are safe for concurrent invocation.

Within a session, the B3 concurrency guard serializes `execute()` calls so
two `monty_session_exec` requests to the same session do not interleave.

### Dual-registration flow

```
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

## Startup Modes

### Standalone (stdio transport)

Run the built-in entry point. Communicates over stdin/stdout using JSON-RPC:

```bash
dart run packages/dart_monty_mcp/bin/dart_monty_mcp.dart \
  --library-path /path/to/libdart_monty_native.dylib
```

The `--library-path` flag can be replaced by setting the `MONTY_LIBRARY_PATH`
environment variable.

### Embedded in another Dart application

```dart
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

final server = MontyMcpServer(
  platformFactory: () => MontyFfi(
    bindings: NativeBindingsFfi(libraryPath: libraryPath),
  ),
  version: '1.0.0',
);

// Register host functions before serving
server.registerPlugin(MyPlugin());

final transport = StdioServerTransport();
await server.serve(transport);
```

### With custom transport

Any `Transport` implementation from `mcp_dart` works:

```dart
final transport = SseServerTransport('/mcp', responseHeaders: {});
await server.serve(transport);
```

### Environment variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `MONTY_LIBRARY_PATH` | `bin/dart_monty_mcp.dart` | Native library path for the standalone entry point |
| `DART_MONTY_LIB_PATH` | `dart_monty_ffi` / test harness | Native library path used by the FFI package and integration tests |

Both resolve to the same shared library (`libdart_monty_native.dylib` on
macOS, `libdart_monty_native.so` on Linux). The integration tests check
`DART_MONTY_LIB_PATH` first, then fall back to `MONTY_LIBRARY_PATH`.

## Session Limitations

Persistent sessions use JSON serialization to save and restore Python state
between calls to `monty_session_exec`.

**What persists across calls:**
- Simple values: `int`, `float`, `str`, `bool`, `None`
- Container values: `list`, `dict` (with simple values inside)

**What does NOT persist:**
- Function definitions (must redefine in each exec call)
- Class instances
- In-place mutations (`data['key'] = val` across calls)
- Augmented assignments (`x += 5` -- use `x = x + 5` instead)

Stateless execution via `monty_run` has no persistence at all. Each call
creates a fresh interpreter and disposes it when done.

## Monty Python Subset

Monty is a restricted Python interpreter. It does **not** include the Python
standard library -- modules like `math`, `json`, `os`, `sys`, `re`, etc. are
not available.

**Supported features:**
- Variables and assignments
- Arithmetic (`+`, `-`, `*`, `/`, `//`, `%`, `**`)
- Comparison and logical operators
- f-strings
- Control flow (`if`/`elif`/`else`, `for`, `while`)
- Function definitions and calls
- List comprehensions
- `try`/`except`
- Built-in functions: `range()`, `len()`, `print()`, `str()`, `int()`,
  `float()`, `bool()`, `list()`, `dict()`, `type()`, `isinstance()`
- Host functions (registered via the API described above)

**Not supported:**
- `import` of standard library modules
- Classes
- Generators / `yield`
- Decorators
- `with` statements
- File I/O
- Network access

The host function system is the intended escape hatch: implement
capabilities in Dart and expose them to Python.

## Tests

```bash
# Unit tests (mock-based, no native library needed)
cd packages/dart_monty_mcp
dart test --exclude-tags=integration

# Integration tests (requires the native library)
DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
  dart test --tags=integration --run-skipped
```

126 total tests: 49 unit + 77 integration (60 core + 17 host function).

Test files:

| File | Scope |
|------|-------|
| `monty_mcp_server_test.dart` | MCP tool registration and routing |
| `monty_session_manager_test.dart` | Session lifecycle, stateless exec |
| `monty_session_test.dart` | Session state persistence, B3 lock |
| `bridge_adapter_test.dart` | Bridge event to MCP result conversion |
| `integration_test.dart` | End-to-end with real FFI interpreter |
| `host_function_integration_test.dart` | Host functions via Python + MCP |

## Architecture

```
MontyMcpServer                    MCP tool registration + host function wiring
  |
  +-- registerHostFunction(fn) ----+
  |     |                          |
  |     v                          v
  |   MontySessionManager        McpServer.registerTool()
  |     (session lifecycle,        (LLM calls fn directly)
  |      stateless exec,
  |      host fn propagation)
  |     |
  |     +-- createSession() --> McpMontySession
  |     |                         |
  |     |                         +-- register(fn)
  |     |                         |     (per-session host fn map)
  |     |                         |
  |     |                         +-- execute(code)
  |     |                               |
  |     |                               +-- B3 concurrency lock
  |     |                               +-- MontySession.start()
  |     |                               +-- dispatch loop:
  |     |                               |     MontyPending -> handler -> resume
  |     |                               +-- MontyComplete -> CallToolResult
  |     |                               |
  |     |                               MontySession
  |     |                                 (state persist/restore preamble)
  |     |                                 |
  |     |                                 MontyPlatform
  |     |                                   (FFI or WASM interpreter)
  |     |
  |     +-- executeStateless(code)
  |           |
  |           +-- DefaultMontyBridge (temp, useFutures: false)
  |           +-- bridge.register(fn) for each host fn
  |           +-- bridge.execute(code) -> Stream<BridgeEvent>
  |           +-- bridgeEventsToResult() -> CallToolResult
  |           +-- dispose bridge + platform
  |
  +-- serve(transport)
        |
        McpServer.connect(transport)
          (stdio, SSE, or custom)
```

### Host function call flow (Python path)

```
LLM calls monty_session_exec(session_id, "result = add(a=3, b=4)")
  |
  v
McpMontySession.execute("result = add(a=3, b=4)")
  |-- acquires B3 lock
  |-- MontySession.start(code, externalFunctions: ["add"])
  |     |
  |     v
  |   Monty interpreter runs Python, hits add() call
  |     |
  |     v
  |   Returns MontyPending(functionName: "add", arguments: [3], kwargs: {b: 4})
  |
  |-- HostFunctionSchema.mapAndValidate(pending)
  |     maps positional [3] -> a=3, merges kwargs {b: 4}
  |     validates types via HostParam.validate()
  |
  |-- handler({a: 3, b: 4}) -> 7
  |
  |-- MontySession.resume(7)
  |     |
  |     v
  |   Interpreter resumes, assigns result = 7
  |     |
  |     v
  |   Returns MontyComplete(result)
  |
  |-- releases B3 lock
  |-- returns CallToolResult(content: [TextContent(text: "7")])
```

### Exported API surface

The barrel file (`lib/dart_monty_mcp.dart`) re-exports:

| Symbol | Source |
|--------|--------|
| `HostFunction`, `HostFunctionHandler` | `dart_monty_bridge` |
| `HostFunctionSchema` | `dart_monty_bridge` |
| `HostParam` | `dart_monty_bridge` |
| `HostParamType` | `dart_monty_bridge` |
| `MontyPlugin` | `dart_monty_bridge` |
| `bridgeEventsToResult`, `montyResultToCallToolResult` | `bridge_adapter.dart` |
| `MontyMcpServer` | `monty_mcp_server.dart` |
| `McpMontySession` | `monty_session.dart` |
| `MontySessionManager`, `PlatformFactory` | `monty_session_manager.dart` |
