# dart_monty_mcp

Give your LLM a Python interpreter. This MCP server lets Claude, Cursor, or
any MCP-compatible client execute Python code, maintain persistent sessions,
and call custom functions you define -- all sandboxed, no `pip install`, no
filesystem access, no network.

## Setup

Add to your Claude Desktop config
(`~/Library/Application Support/Claude/claude_desktop_config.json`):

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

`cwd` should be the root of your cloned `dart_monty` repository.
That's it. Your LLM now has five Python tools.

## What your LLM can do

**Run Python instantly** -- ask it to calculate, transform data, or test
logic. Each `monty_run` call gets a fresh interpreter:

> "What's 2\*\*128?" → LLM calls `monty_run(code: "2**128")`

**Keep state across calls** -- create a session and build up variables:

> "Create a session, set `prices = [10, 20, 30]`, then compute the average"
>
> The LLM creates a session, executes two calls, and the second one sees
> `prices` from the first.

**Call your custom functions from Python** -- register Dart functions as host
functions and they become callable from inside Python *and* as standalone
MCP tools:

> You register `lookup_price(symbol)` in Dart. The LLM can now write
> `price = lookup_price(symbol="AAPL")` inside `monty_session_exec`, or
> call `lookup_price` directly as an MCP tool.

This is where it gets powerful. The interpreter is restricted (no stdlib, no
I/O), but host functions let you give it exactly the capabilities you choose.
See [What Python supports](docs/python_subset.md) for the full language
subset.

## Tools

| Tool | Description |
|------|-------------|
| `monty_run` | Execute Python (stateless, one-shot) |
| `monty_session_create` | Create a persistent session |
| `monty_session_exec` | Execute in a session (variables persist) |
| `monty_session_list` | List active sessions |
| `monty_session_destroy` | Destroy a session |

Plus any host functions you register.

## Going deeper

| Guide | For |
|-------|-----|
| [Client Setup](docs/client_setup.md) | Configuring Claude Desktop, Cursor, soliplex_tui |
| [What Python supports](docs/python_subset.md) | Language features and limitations |
| [Session Persistence](docs/session_persistence.md) | What state survives across calls |
| [Host Functions](docs/host_functions.md) | Extending the interpreter with Dart plugins |
| [Startup Modes](docs/startup_modes.md) | Embedding in your own Dart app, custom transports |
| [Architecture](docs/architecture.md) | Internals, call flows, test suites |
