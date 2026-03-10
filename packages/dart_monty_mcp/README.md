# dart_monty_mcp

MCP (Model Context Protocol) server exposing the Monty sandboxed Python
interpreter as callable tools.

## Tools

| Tool | Description |
|------|-------------|
| `monty_run` | Execute Python in a fresh interpreter (stateless) |
| `monty_session_create` | Create a persistent Python session |
| `monty_session_exec` | Execute code in a persistent session |
| `monty_session_list` | List active sessions |
| `monty_session_destroy` | Destroy a session and free resources |

## Quick Start

### Claude Desktop / MCP Client

Add to your MCP client config:

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

Or set `MONTY_LIBRARY_PATH` environment variable instead of `--library-path`.

### soliplex_tui

```bash
DART_MONTY_LIB_PATH=/path/to/libdart_monty_native.dylib \
  soliplex_tui \
  --llm-provider ollama --llm-model qwen3-coder \
  --mcp monty="/path/to/dart_monty_mcp_server.sh" \
  --verbose --json
```

### Programmatic

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

Register Dart functions as both Python-callable host functions and direct
MCP tools with a single registration point:

```dart
import 'package:dart_monty_mcp/dart_monty_mcp.dart';

final server = MontyMcpServer(platformFactory: createPlatform);

// Register a single function
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

// Or register a plugin with multiple functions
server.registerPlugin(myPlugin);

await server.serve(transport);
```

Each registered function is available in two ways:

1. **From Python** — `result = add(a=3, b=4)` inside `monty_session_exec`
   or `monty_run`
2. **As MCP tool** — the LLM calls `add` directly via MCP protocol

Function names must not start with `monty_` (reserved for built-in tools).

**Thread safety:** Host function handlers may be called concurrently
(direct MCP calls bypass the session lock). Plugin authors should ensure
handlers are safe for concurrent invocation.

## Session Limitations

Persistent sessions use JSON serialization to save/restore Python state.

**What persists:** int, float, str, bool, None, list, dict (simple values).

**What doesn't persist:**
- Functions (must redefine in each exec call)
- Class instances
- In-place mutations (`data['key'] = val` across execs)
- Augmented assignments (`x += 5` — use `x = x + 5` instead)

## Monty Python Subset

Monty is a restricted Python interpreter. No standard library (`math`,
`json`, `os`, etc.) is available. Supported: variables, arithmetic,
f-strings, control flow, functions, list comprehensions, try/except,
`range()`, `len()`, `print()`, `str()`.

## Tests

```bash
# Unit tests (mock-based, no FFI needed)
dart test --exclude-tags=integration

# Integration tests (requires native library)
DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
  dart test --tags=integration --run-skipped
```

126 total tests: 49 unit + 77 integration (60 core + 17 host function).

## Architecture

```
MontyMcpServer         — registers MCP tools, routes to manager
  ├── registerPlugin() — host functions → MCP tools + session functions
  MontySessionManager  — session create/list/destroy + stateless exec
    McpMontySession    — wraps MontySession + host fn dispatch + B3 lock
      MontySession     — state persistence via restore/persist preamble
        MontyPlatform  — FFI or WASM interpreter instance
```
