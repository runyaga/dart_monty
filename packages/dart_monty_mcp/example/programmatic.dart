// This example uses print() to show results.
// ignore_for_file: avoid_print
/// Example: Use MontyMcpServer programmatically without a transport.
///
/// Useful for testing, embedding in CLI tools, or running Python
/// computations from Dart without an MCP client.
/// See docs/startup_modes.md for transport-based usage.
///
/// Run with:
/// ```bash
/// DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///   dart run example/programmatic.dart
/// ```
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

Future<void> main() async {
  final server = MontyMcpServer(
    platformFactory: () => MontyFfi(
      bindings: NativeBindingsFfi(),
    ),
  );

  // --- Stateless one-shot execution ---
  final result = await server.sessionManager.executeStateless('2 + 2');
  final text = (result.content.first as TextContent).text;
  print('Stateless: $text'); // Stateless: 4

  // --- Persistent session ---
  server.sessionManager.createSession(id: 'calc');
  final session = server.sessionManager.getSession('calc')!;

  await session.execute('x = 42');
  final r = await session.execute('x * 2');
  final rText = (r.content.first as TextContent).text;
  print('Session: $rText'); // Session: 84

  await server.sessionManager.destroySession('calc');
  await server.dispose();
}
