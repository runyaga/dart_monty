// This example uses print() to show results.
// ignore_for_file: avoid_print
/// Example: Use MontyMcpServer programmatically without a transport.
///
/// Useful for testing, embedding in CLI tools, or running Python
/// computations from Dart without an MCP client.
/// See docs/startup_modes.md for transport-based usage.
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';

Future<void> main() async {
  final server = MontyMcpServer(
    platformFactory: () => MontyFfi(
      bindings: NativeBindingsFfi(
        libraryPath: '/path/to/libdart_monty_native.dylib',
      ),
    ),
  );

  // --- Stateless one-shot execution ---
  final result = await server.sessionManager.executeStateless('2 + 2');
  print(result.content.first); // TextContent(text: '4')

  // --- Persistent session ---
  server.sessionManager.createSession(id: 'calc');
  final session = server.sessionManager.getSession('calc')!;

  await session.execute('x = 42');
  final r = await session.execute('x * 2');
  print(r.content.first); // TextContent(text: '84')

  await server.sessionManager.destroySession('calc');
  await server.dispose();
}
