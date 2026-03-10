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
print(result.content.first); // TextContent(text: '4')

// Persistent session
server.sessionManager.createSession(id: 'calc');
final session = server.sessionManager.getSession('calc')!;
await session.execute('x = 42');
final r = await session.execute('x * 2'); // 84
await server.sessionManager.destroySession('calc');
```
