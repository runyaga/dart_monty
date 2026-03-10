# Client Setup

Configure MCP clients to connect to the dart_monty_mcp server.

## Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

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

Omit `--library-path` if you set the `MONTY_LIBRARY_PATH` environment
variable instead.

## Cursor

Add the same JSON block to your Cursor MCP configuration. Cursor uses the
same MCP client protocol as Claude Desktop.

## soliplex_tui

```bash
DART_MONTY_LIB_PATH=/path/to/libdart_monty_native.dylib \
  soliplex_tui \
  --llm-provider ollama --llm-model qwen3-coder \
  --mcp monty="/path/to/dart_monty_mcp_server.sh" \
  --verbose --json
```

## Environment Variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `MONTY_LIBRARY_PATH` | `bin/dart_monty_mcp.dart` | Native library path for the standalone entry point |
| `DART_MONTY_LIB_PATH` | `dart_monty_ffi` / test harness | Native library path used by the FFI package and integration tests |

Both resolve to the same shared library (`libdart_monty_native.dylib` on
macOS, `libdart_monty_native.so` on Linux). Two separate variables exist to
keep the standalone server binary configuration distinct from the FFI
package's default path used during development and testing. The integration
tests check `DART_MONTY_LIB_PATH` first, then fall back to
`MONTY_LIBRARY_PATH`.
