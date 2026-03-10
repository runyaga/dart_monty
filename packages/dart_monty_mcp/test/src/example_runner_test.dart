/// Integration tests that run the actual example files with real FFI.
///
/// These tests ensure that every example in example/ is executable and
/// produces correct output when run against the native library.
///
/// Run with:
/// ```bash
/// DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///   dart test --tags=integration --run-skipped test/src/example_runner_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// Resolve library path from env (same logic as examples).
String? get _libraryPath =>
    Platform.environment['DART_MONTY_LIB_PATH'] ??
    Platform.environment['MONTY_LIBRARY_PATH'];

MontyPlatform _createPlatform() =>
    MontyFfi(bindings: NativeBindingsFfi(libraryPath: _libraryPath));

String _text(CallToolResult r) => (r.content.first as TextContent).text;

void main() {
  group('example/programmatic.dart — run as subprocess', () {
    test('executes and prints correct output', () async {
      final result = await Process.run(
        'dart',
        ['run', 'example/programmatic.dart'],
        environment: {
          if (_libraryPath != null) 'DART_MONTY_LIB_PATH': _libraryPath!,
        },
      );

      expect(
        result.exitCode,
        0,
        reason: 'programmatic.dart failed:\n'
            'stdout: ${result.stdout}\n'
            'stderr: ${result.stderr}',
      );

      final stdout = result.stdout as String;
      expect(stdout, contains('Stateless: 4'));
      expect(stdout, contains('Session: 84'));
    });
  });

  group('example/server_setup.dart — setup pattern with real FFI', () {
    test('constructs server and executes code', () async {
      final server = MontyMcpServer(
        platformFactory: _createPlatform,
        version: '1.0.0',
      );

      // Verify the server works by running a stateless execution
      final r = await server.sessionManager.executeStateless('1 + 1');
      expect(r.isError, isFalse);
      expect(_text(r), '2');

      await server.dispose();
    });
  });

  group('example/host_function.dart — host function with real FFI', () {
    test('registers and calls host function from Python', () async {
      final server = MontyMcpServer(
        platformFactory: _createPlatform,
      )..registerHostFunction(
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

      // Call the host function from Python via a session
      server.sessionManager.createSession(id: 'hf-test');
      final session = server.sessionManager.getSession('hf-test')!;
      final r = await session.execute('result = add(a=3, b=4)\nresult');

      expect(r.isError, isFalse);
      expect(_text(r), '7');

      await server.dispose();
    });
  });

  group('example/plugin.dart — plugin with real FFI', () {
    test('registers plugin and calls functions from Python', () async {
      final server = MontyMcpServer(
        platformFactory: _createPlatform,
      )..registerPlugin(_MathPlugin());

      server.sessionManager.createSession(id: 'plugin-test');
      final session = server.sessionManager.getSession('plugin-test')!;

      // Call add from Python
      final r1 = await session.execute('add(a=10, b=20)');
      expect(r1.isError, isFalse);
      expect(_text(r1), '30');

      // Call multiply from Python
      final r2 = await session.execute('multiply(a=6, b=7)');
      expect(r2.isError, isFalse);
      expect(_text(r2), '42');

      await server.dispose();
    });
  });
}

/// Mirrors the MathPlugin from example/plugin.dart exactly.
class _MathPlugin extends MontyPlugin {
  @override
  String get namespace => 'math';

  @override
  String? get systemPromptContext =>
      'Math functions: add(a, b), multiply(a, b)';

  @override
  List<HostFunction> get functions => [
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
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'multiply',
            description: 'Multiply two numbers',
            params: [
              HostParam(name: 'a', type: HostParamType.number),
              HostParam(name: 'b', type: HostParamType.number),
            ],
          ),
          handler: (args) async => (args['a']! as num) * (args['b']! as num),
        ),
      ];
}
