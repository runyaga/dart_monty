/// Example: Register a host function callable from Python and as an MCP tool.
///
/// See docs/host_functions.md for parameter types, optional params, and
/// JSON Schema overrides.
///
/// Run with:
/// ```bash
/// DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///   dart run example/host_function.dart
/// ```
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

Future<void> main() async {
  final libraryPath = Platform.environment['DART_MONTY_LIB_PATH'] ??
      Platform.environment['MONTY_LIBRARY_PATH'];

  final server = MontyMcpServer(
    platformFactory: () => MontyFfi(
      bindings: NativeBindingsFfi(libraryPath: libraryPath),
    ),
  )
    // Register before serving. The function becomes:
    // 1. Callable from Python: result = add(a=3, b=4)
    // 2. Callable as a standalone MCP tool by the LLM
    ..registerHostFunction(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'add',
          description: 'Add two numbers',
          params: [
            HostParam(name: 'a', type: HostParamType.number),
            HostParam(name: 'b', type: HostParamType.number),
          ],
        ),
        handler: (args) async => (args['a']! as num) + (args['b']! as num),
      ),
    );

  await server.serve(StdioServerTransport());
}
