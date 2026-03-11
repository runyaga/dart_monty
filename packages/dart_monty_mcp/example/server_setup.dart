/// Example: Create and serve a MontyMcpServer over stdio.
///
/// This is the minimal setup for running dart_monty_mcp as a standalone
/// MCP server. See docs/startup_modes.md for more options.
///
/// Run with:
/// ```bash
/// DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///   dart run example/server_setup.dart
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
    version: '1.0.0',
  );

  await server.serve(StdioServerTransport());
}
