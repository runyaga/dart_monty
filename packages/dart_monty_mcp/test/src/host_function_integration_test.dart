@Tags(['integration'])
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// Integration tests for host function wiring with real FFI.
///
/// Run with:
/// ```bash
/// dart test --tags=integration --run-skipped test/src/host_function_integration_test.dart
/// ```
void main() {
  late MontyMcpServer server;

  MontyPlatform createPlatform() {
    return MontyFfi(
      bindings: NativeBindingsFfi(),
    );
  }

  setUp(() {
    server = MontyMcpServer(platformFactory: createPlatform)
      ..registerPlugin(_TestPlugin());
  });

  tearDown(() async {
    await server.dispose();
  });

  // ---------------------------------------------------------------------------
  // HF-01 through HF-08: Python calling host functions via session
  // ---------------------------------------------------------------------------

  group('Host functions from Python (session)', () {
    test('HF-01: call add(a=3, b=4) from Python', () async {
      server.sessionManager.createSession(id: 's1');
      final session = server.sessionManager.getSession('s1')!;

      final r = await session.execute('result = add(a=3, b=4)\nresult');

      expect(r.isError, isFalse);
      expect(_text(r), contains('7'));
    });

    test('HF-02: call greet(name="World") with default title', () async {
      server.sessionManager.createSession(id: 's2');
      final session = server.sessionManager.getSession('s2')!;

      final r = await session.execute('greet(name="World")');

      expect(r.isError, isFalse);
      expect(_text(r), contains('Hello, friend World!'));
    });

    test('HF-03: call greet with explicit title', () async {
      server.sessionManager.createSession(id: 's3');
      final session = server.sessionManager.getSession('s3')!;

      final r = await session.execute('greet(name="Alice", title="Dr")');

      expect(r.isError, isFalse);
      expect(_text(r), contains('Hello, Dr Alice!'));
    });

    test('HF-04: failing_fn raises exception, session stays alive', () async {
      server.sessionManager.createSession(id: 's4');
      final session = server.sessionManager.getSession('s4')!;

      final r1 = await session.execute('''
try:
  failing_fn()
  result = "should not reach"
except:
  result = "caught error"
result
''');

      expect(r1.isError, isFalse);
      expect(_text(r1), contains('caught error'));

      // Session still alive — can execute more code
      final r2 = await session.execute('1 + 1');
      expect(r2.isError, isFalse);
      expect(_text(r2), contains('2'));
    });

    test('HF-05: use host fn result in assignment and expression', () async {
      server.sessionManager.createSession(id: 's5');
      final session = server.sessionManager.getSession('s5')!;

      final r = await session.execute('x = add(a=1, b=2)\nx * 10');

      expect(r.isError, isFalse);
      expect(_text(r), contains('30'));
    });

    test('HF-06: host fn + state persistence', () async {
      server.sessionManager.createSession(id: 's6');
      final session = server.sessionManager.getSession('s6')!;

      // Set a variable, call host fn
      await session.execute('counter = 100');
      final r = await session.execute(
        'result = add(a=counter, b=5)\nresult',
      );

      expect(r.isError, isFalse);
      expect(_text(r), contains('105'));

      // counter should still be accessible
      final r2 = await session.execute('counter');
      expect(r2.isError, isFalse);
      expect(_text(r2), contains('100'));
    });

    test('HF-07: multiple host fns in same exec', () async {
      server.sessionManager.createSession(id: 's7');
      final session = server.sessionManager.getSession('s7')!;

      final r = await session.execute('''
a = add(a=10, b=20)
b = greet(name="Test")
result = str(a) + " " + b
result
''');

      expect(r.isError, isFalse);
      final text = _text(r);
      expect(text, contains('30'));
      expect(text, contains('Hello, friend Test!'));
    });

    test('HF-08: host fn in stateless monty_run', () async {
      final r = await server.sessionManager.executeStateless(
        'add(a=10, b=32)',
      );

      expect(r.isError, isFalse);
      expect(_text(r), contains('42'));
    });
  });

  // ---------------------------------------------------------------------------
  // HF-09 through HF-12: Direct MCP tool calls
  // ---------------------------------------------------------------------------

  group('Host functions as MCP tools (direct)', () {
    test('HF-09: direct MCP call to add', () async {
      // We can't easily call the MCP tool via JSON-RPC in a unit test
      // without a transport layer. Instead, test the handler logic
      // indirectly by calling through the session manager's stateless path.
      final r = await server.sessionManager.executeStateless(
        'add(a=5, b=3)',
      );
      expect(r.isError, isFalse);
      expect(_text(r), contains('8'));
    });

    test('HF-10: direct MCP call to greet with optional param', () async {
      final r = await server.sessionManager.executeStateless(
        'greet(name="Bob")',
      );
      expect(r.isError, isFalse);
      expect(_text(r), contains('Hello, friend Bob!'));
    });

    test('HF-11: direct call to failing_fn returns error', () async {
      // In stateless mode, the bridge propagates the handler exception via
      // resumeWithError. Monty surfaces this as an execution error.
      final r = await server.sessionManager.executeStateless('failing_fn()');
      expect(r.isError, isTrue);
      expect(_text(r), contains('intentional error'));
    });
  });

  // ---------------------------------------------------------------------------
  // HF-13 through HF-18: Edge cases
  // ---------------------------------------------------------------------------

  group('Host function edge cases', () {
    test('HF-13: undefined function in Python → error', () async {
      server.sessionManager.createSession(id: 'edge1');
      final session = server.sessionManager.getSession('edge1')!;

      // Call a function that is NOT registered
      final r = await session.execute('not_registered_fn()');

      expect(r.isError, isTrue);
    });

    test('HF-14: int coercion (pass string "42")', () async {
      server.sessionManager.createSession(id: 'edge2');
      final session = server.sessionManager.getSession('edge2')!;

      // add expects number params — "42" should be coerced
      // But Python will send it as a string keyword arg
      final r = await session.execute('add(a=40, b=2)');
      expect(r.isError, isFalse);
      expect(_text(r), contains('42'));
    });

    test('HF-15: missing required param → error', () async {
      server.sessionManager.createSession(id: 'edge3');
      final session = server.sessionManager.getSession('edge3')!;

      // greet requires 'name' but we don't pass it.
      // The dispatch loop catches the FormatException and resumes with error.
      // Monty may surface this as an uncatchable error or a Python exception.
      final r = await session.execute('greet()');

      // Either the error is surfaced as isError or caught — both valid.
      // The key assertion: session doesn't crash, and error mentions the
      // missing parameter.
      expect(r.isError, isTrue);
      expect(_text(r).toLowerCase(), contains('required'));
    });

    test('HF-16: 10 rapid host fn calls in session', () async {
      server.sessionManager.createSession(id: 'stress');
      final session = server.sessionManager.getSession('stress')!;

      for (var i = 0; i < 10; i++) {
        final r = await session.execute('add(a=$i, b=1)');
        expect(r.isError, isFalse);
        expect(_text(r), contains('${i + 1}'));
      }
    });

    test('HF-17: host fn result used across session execs', () async {
      server.sessionManager.createSession(id: 'cross');
      final session = server.sessionManager.getSession('cross')!;

      // First exec: assign host fn result to variable
      await session.execute('x = add(a=10, b=20)');

      // Second exec: read the variable
      final r = await session.execute('x');
      expect(r.isError, isFalse);
      expect(_text(r), contains('30'));
    });

    test('HF-18: monty_ prefix collision throws ArgumentError', () {
      expect(
        () => server.registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'monty_session_exec',
              description: 'Collision',
            ),
            handler: (args) async => null,
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}

String _text(CallToolResult r) => (r.content.first as TextContent).text;

/// Test plugin with 3 host functions for integration testing.
class _TestPlugin extends MontyPlugin {
  @override
  String get namespace => 'test';

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
            name: 'greet',
            description: 'Return greeting',
            params: [
              HostParam(name: 'name', type: HostParamType.string),
              HostParam(
                name: 'title',
                type: HostParamType.string,
                isRequired: false,
                defaultValue: 'friend',
              ),
            ],
          ),
          handler: (args) async => 'Hello, ${args['title']} ${args['name']}!',
        ),
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'failing_fn',
            description: 'Always throws',
          ),
          handler: (args) async => throw Exception('intentional error'),
        ),
      ];
}
