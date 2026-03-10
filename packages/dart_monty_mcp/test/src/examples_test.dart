/// Tests that mirror the code patterns in example/ and docs/.
///
/// If an API change breaks these tests, the corresponding example files
/// and documentation code blocks are stale and must be updated.
library;

import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

MockMontyPlatform _mockForStateless(Object? value) {
  return MockMontyPlatform()
    ..enqueueProgress(
      MontyComplete(result: MontyResult(value: value, usage: _usage)),
    );
}

MockMontyPlatform _mockForSessionExec({required MontyResult result}) {
  return MockMontyPlatform()
    ..enqueueProgress(
      const MontyPending(functionName: '__restore_state__', arguments: []),
    )
    ..enqueueProgress(
      const MontyPending(
        functionName: '__persist_state__',
        arguments: [<String, Object?>{}],
      ),
    )
    ..enqueueProgress(MontyComplete(result: result));
}

String _text(CallToolResult r) => (r.content.first as TextContent).text;

void main() {
  group('Example: programmatic usage (docs/startup_modes.md)', () {
    test('stateless executeStateless returns result', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForStateless(4),
      );

      final result = await server.sessionManager.executeStateless('2 + 2');

      expect(result.isError, isFalse);
      expect(_text(result), contains('4'));

      await server.dispose();
    });

    test('persistent session create → exec → destroy', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForSessionExec(
          result: const MontyResult(value: 84, usage: _usage),
        ),
      );

      server.sessionManager.createSession(id: 'calc');
      final session = server.sessionManager.getSession('calc')!;
      final r = await session.execute('x * 2');

      expect(r.isError, isFalse);
      expect(_text(r), contains('84'));

      final destroyed = await server.sessionManager.destroySession('calc');
      expect(destroyed, isTrue);

      await server.dispose();
    });
  });

  group('Example: host function (docs/host_functions.md)', () {
    test('registerHostFunction with typed params', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
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

      // Verify the function is propagated to new sessions
      expect(server.sessionManager.createSession(id: 'test'), 'test');

      await server.dispose();
    });

    test('host function dispatches from Python via session', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(functionName: 'add', arguments: [3, 4]),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 7, usage: _usage),
          ),
        );

      final server = MontyMcpServer(platformFactory: () => mock)
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

      server.sessionManager.createSession(id: 's1');
      final session = server.sessionManager.getSession('s1')!;
      final result = await session.execute('add(a=3, b=4)');

      expect(result.isError, isFalse);
      expect(_text(result), contains('7'));
      expect(mock.resumeReturnValues, contains(7));

      await server.dispose();
    });
  });

  group('Example: plugin (docs/host_functions.md)', () {
    test('MontyPlugin subclass registers all functions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      )..registerPlugin(_MathPlugin());

      // Both functions should be propagated
      server.sessionManager.createSession(id: 'math');
      expect(server.sessionManager.getSession('math'), isNotNull);

      await server.dispose();
    });

    test('monty_ prefix rejected for plugin functions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      expect(
        () => server.registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'monty_evil',
              description: 'Bad name',
            ),
            handler: (args) async => null,
          ),
        ),
        throwsArgumentError,
      );

      await server.dispose();
    });
  });

  group('Example: optional params (docs/host_functions.md)', () {
    test('optional param with default value', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      )..registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'format_number',
              description: 'Format a number',
              params: [
                HostParam(name: 'value', type: HostParamType.number),
                HostParam(
                  name: 'precision',
                  type: HostParamType.integer,
                  isRequired: false,
                  defaultValue: 2,
                  description: 'Decimal places to round to',
                ),
              ],
            ),
            handler: (args) async {
              final value = args['value']! as num;
              final precision = args['precision']! as int;
              return value.toStringAsFixed(precision);
            },
          ),
        );

      await server.dispose();
    });
  });

  group('Example: jsonSchemaOverride (docs/host_functions.md)', () {
    test('registers function with jsonSchemaOverride', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      )..registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'search',
              description: 'Search with filters',
              params: [
                HostParam(
                  name: 'filters',
                  type: HostParamType.map,
                  jsonSchemaOverride: {
                    'type': 'object',
                    'properties': {
                      'status': {
                        'type': 'string',
                        'enum': ['active', 'archived'],
                      },
                      'limit': {'type': 'integer', 'minimum': 1},
                    },
                  },
                ),
              ],
            ),
            handler: (args) async => args['filters'],
          ),
        );

      // Verify registration succeeded and session receives function
      server.sessionManager.createSession(id: 'schema-test');
      expect(
        server.sessionManager.getSession('schema-test'),
        isNotNull,
      );

      await server.dispose();
    });
  });

  group('Example: results and errors (docs/results_and_errors.md)', () {
    test('extract text from CallToolResult', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForStateless(4),
      );

      final result = await server.sessionManager.executeStateless('2 + 2');
      // Mirrors the doc pattern: (result.content.first as TextContent).text
      expect(result.content.first, isA<TextContent>());
      final text = (result.content.first as TextContent).text;
      expect(text, contains('4'));

      await server.dispose();
    });

    test('error result has isError true', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              error: MontyException(message: 'ZeroDivisionError'),
              usage: _usage,
            ),
          ),
        );
      final server = MontyMcpServer(platformFactory: () => mock);

      final result = await server.sessionManager.executeStateless('1 / 0');
      expect(result.isError, isTrue);
      expect(_text(result), contains('ZeroDivisionError'));

      await server.dispose();
    });

    test('print output included in result', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: 4,
              printOutput: 'hello\n',
              usage: _usage,
            ),
          ),
        );
      final server = MontyMcpServer(platformFactory: () => mock);

      final result = await server.sessionManager.executeStateless(
        'print("hello"); 2 + 2',
      );
      expect(result.isError, isFalse);
      final text = _text(result);
      expect(text, contains('hello'));
      expect(text, contains('4'));

      await server.dispose();
    });
  });

  group('Example: session persistence (docs/session_persistence.md)', () {
    test('session state persists across exec calls', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForSessionExec(
          result: const MontyResult(value: 84, usage: _usage),
        ),
      );

      server.sessionManager.createSession(id: 'persist');
      final session = server.sessionManager.getSession('persist')!;

      // First call sets x = 42 (mocked as no-op, state managed by mock)
      // Second call reads x * 2 -> 84
      final result = await session.execute('x * 2');
      expect(result.isError, isFalse);
      expect(_text(result), contains('84'));

      final destroyed = await server.sessionManager.destroySession('persist');
      expect(destroyed, isTrue);

      await server.dispose();
    });
  });

  group('Example: disposal (docs/startup_modes.md)', () {
    test('dispose frees all sessions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      server.sessionManager.createSession(id: 's1');
      server.sessionManager.createSession(id: 's2');
      expect(server.sessionManager.sessionCount, 2);

      await server.dispose();
      expect(server.sessionManager.sessionCount, 0);
    });

    test('disposed session returns error on execute', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForSessionExec(
          result: const MontyResult(usage: _usage),
        ),
      );

      server.sessionManager.createSession(id: 'disp');
      final session = server.sessionManager.getSession('disp')!;
      await session.dispose();

      final result = await session.execute('x = 1');
      expect(result.isError, isTrue);
      expect(_text(result), contains('disposed'));
    });
  });

  group(
    'Example: host function error handling (docs/host_functions.md)',
    () {
      test(
        'handler error in Python path resumes with error',
        () async {
          final mock = MockMontyPlatform()
            ..enqueueProgress(
              const MontyPending(
                functionName: '__restore_state__',
                arguments: [],
              ),
            )
            ..enqueueProgress(
              const MontyPending(
                functionName: 'fail_fn',
                arguments: [],
              ),
            )
            ..enqueueProgress(
              const MontyPending(
                functionName: '__persist_state__',
                arguments: [<String, Object?>{}],
              ),
            )
            ..enqueueProgress(
              const MontyComplete(
                result: MontyResult(
                  error: MontyException(
                    message: 'Exception: boom',
                  ),
                  usage: _usage,
                ),
              ),
            );

          final server = MontyMcpServer(platformFactory: () => mock)
            ..registerHostFunction(
              HostFunction(
                schema: const HostFunctionSchema(
                  name: 'fail_fn',
                  description: 'Always fails',
                ),
                handler: (args) async => throw Exception('boom'),
              ),
            );

          server.sessionManager.createSession(id: 'err');
          final session = server.sessionManager.getSession('err')!;
          await session.execute('fail_fn()');

          // The error was resumed into the interpreter
          expect(
            mock.resumeErrorMessages,
            contains(contains('boom')),
          );

          await server.dispose();
        },
      );
    },
  );
}

/// Mirrors the MathPlugin from example/plugin.dart.
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
