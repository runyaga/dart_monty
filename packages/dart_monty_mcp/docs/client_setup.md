# Client Setup

Configure MCP clients to connect to the dart_monty_mcp server.

## Building the native library

The server requires a compiled native library. Build it with the Rust
toolchain:

```bash
# from the root of the dart_monty repository
cd native
cargo build --release
cd ..
```

The library will be at `native/target/release/libdart_monty_native.dylib`
on macOS or `native/target/release/libdart_monty_native.so` on Linux. Use
this path when configuring clients below.

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

You can omit `--library-path` if you set the `MONTY_LIBRARY_PATH`
environment variable instead. The command-line argument takes precedence
if both are present.

## Cursor

Add the same JSON block to your Cursor MCP configuration. Cursor uses the
same MCP client protocol as Claude Desktop.

## soliplex_tui

```bash
MONTY_LIBRARY_PATH=/path/to/libdart_monty_native.dylib \
  soliplex_tui \
  --llm-provider ollama --llm-model qwen3-coder \
  --mcp monty="/path/to/dart_monty_mcp_server.sh" \
  --verbose --json
```

The `dart_monty_mcp_server.sh` is a wrapper script you create. For example:

```bash
#!/bin/bash
# dart_monty_mcp_server.sh
REPO_ROOT="/path/to/dart_monty"
dart run "${REPO_ROOT}/packages/dart_monty_mcp/bin/dart_monty_mcp.dart" \
  --library-path "${MONTY_LIBRARY_PATH}"
```

Make the script executable: `chmod +x dart_monty_mcp_server.sh`.

## Environment variables

You can provide the native library path via the `--library-path` argument
or an environment variable.

| Variable | Purpose |
|----------|---------|
| `MONTY_LIBRARY_PATH` | **For standalone server.** Sets a default native library path. The `--library-path` argument takes precedence if both are set. |
| `DART_MONTY_LIB_PATH` | **For development/testing.** Used by `dart test` and the underlying `dart_monty_ffi` package to find the library without command-line args. |

For most use cases, setting `MONTY_LIBRARY_PATH` is all you need.
