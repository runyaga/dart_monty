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
  final server = MontyMcpServer(
    platformFactory: () => MontyFfi(
      bindings: NativeBindingsFfi(),
    ),
  );

  final transport = StdioServerTransport();
  await server.serve(transport);
}
