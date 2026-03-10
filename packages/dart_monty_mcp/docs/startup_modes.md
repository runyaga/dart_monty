# Startup Modes

> **Runnable examples:** See
> [`example/server_setup.dart`](../example/server_setup.dart) and
> [`example/programmatic.dart`](../example/programmatic.dart). These are
> tested in CI via `test/src/examples_test.dart`.

## Standalone (stdio transport)

The server can run as a standalone process communicating over stdin/stdout
using JSON-RPC. This is the primary method for connecting LLM clients like
Claude Desktop and Cursor. See the
[Client Setup Guide](client_setup.md) for command-line usage and client
configuration.

## Embedded in another Dart application

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

## Custom transport

Any `Transport` implementation from `mcp_dart` works:

```dart
final transport = SseServerTransport('/mcp', responseHeaders: {});
await server.serve(transport);
```

## Programmatic usage (no transport)

Use the session manager directly for testing or embedding:

```dart
final server = MontyMcpServer(
  platformFactory: () => MontyFfi(
    bindings: NativeBindingsFfi(libraryPath: '/path/to/lib'),
  ),
);

// Stateless execution
final result = await server.sessionManager.executeStateless('2 + 2');
final text = (result.content.first as TextContent).text;
print(text); // '4'

// Persistent session
server.sessionManager.createSession(id: 'calc');
final session = server.sessionManager.getSession('calc')!;
await session.execute('x = 42');
final r = await session.execute('x * 2');
final rText = (r.content.first as TextContent).text;
print(rText); // '84'

await server.dispose();
```

## Key concepts

### The PlatformFactory

The `platformFactory` parameter is a function that returns a new
`MontyPlatform` instance. The server calls this factory every time it
needs a fresh, isolated Python interpreter -- once for each new session
and once for every stateless `monty_run` call. This ensures sessions
cannot interfere with each other.

```dart
// Each call creates an independent interpreter:
MontyMcpServer(
  platformFactory: () => MontyFfi(
    bindings: NativeBindingsFfi(libraryPath: libraryPath),
  ),
);
```

### Handling results

All execution methods return `Future<CallToolResult>`. See
[Handling Results and Errors](results_and_errors.md) for the full guide
on extracting text output, handling errors, and understanding how
`print()` output is captured.

### Disposing resources

The `MontyPlatform` allocates native resources for the Rust interpreter.
It is important to release them when done:

| Method | Scope |
|--------|-------|
| `McpMontySession.dispose()` | Frees a single session's resources |
| `MontySessionManager.destroySession(id)` | Finds a session by ID and disposes it |
| `MontyMcpServer.dispose()` | Disposes **all** active sessions |

Always call `server.dispose()` when your application shuts down. Failure
to dispose sessions will leak native memory.
