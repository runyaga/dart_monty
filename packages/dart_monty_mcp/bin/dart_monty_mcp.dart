import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

/// Standalone MCP server entry point.
///
/// Communicates over stdio (JSON-RPC). Connect this as an MCP server in
/// Claude Desktop, Cursor, or any MCP client:
///
/// ```json
/// {
///   "mcpServers": {
///     "monty": {
///       "command": "dart",
///       "args": ["run", "packages/dart_monty_mcp/bin/dart_monty_mcp.dart"]
///     }
///   }
/// }
/// ```
void main(List<String> args) async {
  final libraryPath = _resolveLibraryPath(args);

  final server = MontyMcpServer(
    platformFactory: () => MontyFfi(
      bindings: NativeBindingsFfi(libraryPath: libraryPath),
    ),
  );

  final transport = StdioServerTransport();
  await server.serve(transport);
}

/// Resolves the native library path from args or environment.
String? _resolveLibraryPath(List<String> args) {
  // --library-path <path>
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--library-path') return args[i + 1];
  }

  final envPath = Platform.environment['MONTY_LIBRARY_PATH'];
  if (envPath != null && envPath.isNotEmpty) return envPath;

  return null;
}
