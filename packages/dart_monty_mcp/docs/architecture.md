# Architecture

## Component tree

```text
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

## Host function call flow (Python path)

```text
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

## Key classes

- **`MontyMcpServer`**: Top-level entry point. Registers built-in tools,
  host functions, and connects to a transport.
- **`MontySessionManager`**: Manages session lifecycle and stateless
  execution. Owns the `PlatformFactory` and host function list.
- **`McpMontySession`**: A persistent session wrapping `MontySession` with
  B3 concurrency lock and host function dispatch loop. Returns
  `CallToolResult` directly.
- **`MontySession`** (from `dart_monty_bridge`): Lower-level session that
  handles state persist/restore preamble. Used internally by
  `McpMontySession`.
- **`bridgeEventsToResult`** / **`montyResultToCallToolResult`**: Adapter
  functions that convert interpreter output to MCP `CallToolResult`. See
  [Handling Results and Errors](results_and_errors.md).

## Exported API surface

The barrel file (`lib/dart_monty_mcp.dart`) re-exports:

| Symbol | Origin |
|--------|--------|
| `HostFunction`, `HostFunctionHandler` | Re-exported from `package:dart_monty_bridge` |
| `HostFunctionSchema` | Re-exported from `package:dart_monty_bridge` |
| `HostParam`, `HostParamType` | Re-exported from `package:dart_monty_bridge` |
| `MontyPlugin` | Re-exported from `package:dart_monty_bridge` |
| `bridgeEventsToResult`, `montyResultToCallToolResult` | Defined in `src/bridge_adapter.dart` |
| `MontyMcpServer` | Defined in `src/monty_mcp_server.dart` |
| `McpMontySession` | Defined in `src/monty_session.dart` |
| `MontySessionManager`, `PlatformFactory` | Defined in `src/monty_session_manager.dart` |

## Tests

```bash
# Unit tests (mock-based, no native library needed)
cd packages/dart_monty_mcp
dart test --exclude-tags=integration

# Integration tests (requires the native library)
DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
  dart test --tags=integration --run-skipped
```

76 unit tests, plus integration tests requiring the native library.

| File | Scope |
|------|-------|
| `examples_test.dart` | **CI validation for doc/example code patterns** |
| `monty_mcp_server_test.dart` | MCP tool registration and routing |
| `monty_session_manager_test.dart` | Session lifecycle, stateless exec |
| `monty_session_test.dart` | Session state persistence, B3 lock |
| `bridge_adapter_test.dart` | Bridge event to MCP result conversion |
| `integration_test.dart` | End-to-end with real FFI interpreter |
| `host_function_integration_test.dart` | Host functions via Python + MCP |
