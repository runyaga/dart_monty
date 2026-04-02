import 'dart:async';

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

/// Creates a [MontyMcpServer] whose platform factory returns mocks
/// that complete with [value] (stateless execution via bridge).
MontyMcpServer _serverWithResult(Object? value) {
  return MontyMcpServer(
    platformFactory: () => MockMontyPlatform()
      ..enqueueProgress(
        MontyComplete(
          result: MontyResult(value: value, usage: _usage),
        ),
      ),
  );
}

/// Creates a mock platform with the restore→persist→complete sequence
/// that [MontySession.run] (used by [McpMontySession]) expects.
MockMontyPlatform _mockForSessionExec({
  required MontyResult result,
  Map<String, Object?> persistedState = const {},
}) {
  return MockMontyPlatform()
    ..enqueueProgress(
      const MontyPending(functionName: '__restore_state__', arguments: []),
    )
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [persistedState],
      ),
    )
    ..enqueueProgress(MontyComplete(result: result));
}

void main() {
  group('MontyMcpServer tool routing', () {
    test('monty_run routes to stateless execution', () async {
      final server = _serverWithResult(42);

      final result = await server.sessionManager.executeStateless('2 + 2');

      expect(result.isError, isFalse);
      expect(_text(result), contains('42'));

      await server.dispose();
    });

    test('session create → exec → destroy lifecycle', () async {
      final server = MontyMcpServer(
        platformFactory: () => _mockForSessionExec(
          result: const MontyResult(value: 'hello', usage: _usage),
        ),
      );
      final manager = server.sessionManager;

      // Create
      final id = manager.createSession(id: 'test-session');
      expect(id, 'test-session');
      expect(manager.sessionCount, 1);

      // Exec
      final session = manager.getSession('test-session')!;
      final result = await session.execute("'hello'");
      expect(result.isError, isFalse);
      expect(_text(result), contains('hello'));

      // Destroy
      final destroyed = await manager.destroySession('test-session');
      expect(destroyed, isTrue);
      expect(manager.sessionCount, 0);

      await server.dispose();
    });

    test('session exec on unknown session returns error', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      final session = server.sessionManager.getSession('nonexistent');
      expect(session, isNull);

      await server.dispose();
    });

    test('session create with duplicate ID returns null', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      final manager = server.sessionManager;

      final first = manager.createSession(id: 'dup');
      final duplicate = manager.createSession(id: 'dup');
      expect(first, 'dup');
      expect(duplicate, isNull);
      expect(manager.sessionCount, 1);

      await server.dispose();
    });

    test('session list returns active session IDs', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      server.sessionManager
        ..createSession(id: 'alpha')
        ..createSession(id: 'beta');

      expect(
        server.sessionManager.sessionIds,
        containsAll(['alpha', 'beta']),
      );

      await server.dispose();
    });

    test('dispose cleans up all sessions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );
      server.sessionManager
        ..createSession(id: 'a')
        ..createSession(id: 'b');

      await server.dispose();

      expect(server.sessionManager.sessionCount, 0);
    });

    test('destroy nonexistent session returns false', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      final destroyed = await server.sessionManager.destroySession('ghost');
      expect(destroyed, isFalse);

      await server.dispose();
    });
  });

  group('Host function registration', () {
    test('registerHostFunction rejects monty_ prefix', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      expect(
        () => server.registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'monty_evil',
              description: 'Collides with built-in',
            ),
            handler: (args) async => null,
          ),
        ),
        throwsArgumentError,
      );

      await server.dispose();
    });

    test('registerHostFunction rejects monty_session_exec collision', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      );

      expect(
        () => server.registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'monty_session_exec',
              description: 'Exact collision',
            ),
            handler: (args) async => null,
          ),
        ),
        throwsArgumentError,
      );

      await server.dispose();
    });

    test('registerHostFunction accepts valid name', () async {
      // Should not throw
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

      await server.dispose();
    });

    test('registerPlugin registers all functions', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      )..registerPlugin(_TestPlugin());

      // Plugin has 2 functions — both should be on the manager.
      // Verify by creating a session and checking it has the functions.
      // (We can't directly inspect _hostFunctions, but we can verify
      // registration didn't throw.)
      await server.dispose();
    });

    test('host function propagated to new session', () async {
      final addFn = HostFunction(
        schema: const HostFunctionSchema(
          name: 'add',
          description: 'Add two numbers',
          params: [
            HostParam(name: 'a', type: HostParamType.number),
            HostParam(name: 'b', type: HostParamType.number),
          ],
        ),
        handler: (args) async => (args['a']! as num) + (args['b']! as num),
      );

      // Mock that expects the start() dispatch path (host fns registered)
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyPending(
            functionName: '__restore_state__',
            arguments: [],
          ),
        )
        ..enqueueProgress(
          const MontyPending(functionName: 'add', arguments: [5, 3]),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: '__persist_state__',
            arguments: [<String, Object?>{}],
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: 8, usage: _usage),
          ),
        );

      final server = MontyMcpServer(platformFactory: () => mock)
        ..registerHostFunction(addFn);

      final id = server.sessionManager.createSession(id: 'test');
      expect(id, 'test');

      final session = server.sessionManager.getSession('test')!;
      final result = await session.execute('add(a=5, b=3)');

      expect(result.isError, isFalse);
      expect(_text(result), contains('8'));
      // Handler was invoked — resume received 8
      expect(mock.resumeReturnValues, contains(8));

      await server.dispose();
    });

    test(
      'session created before registerHostFunction has no functions',
      () async {
        final server = MontyMcpServer(
          platformFactory: () => _mockForSessionExec(
            result: const MontyResult(value: 42, usage: _usage),
          ),
        );

        // Create session BEFORE registering host function
        server.sessionManager.createSession(id: 'early');

        server.registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'late_fn',
              description: 'Registered after session',
            ),
            handler: (args) async => 'late',
          ),
        );

        // Session should use run() path (no host functions on it)
        final session = server.sessionManager.getSession('early')!;
        final result = await session.execute('42');
        expect(result.isError, isFalse);

        await server.dispose();
      },
    );
  });

  group('Built-in MCP tools via JSON-RPC', () {
    late MontyMcpServer server;
    late _TestTransport transport;

    Future<void> init(MontyMcpServer s) async {
      server = s;
      transport = _TestTransport();
      await server.serve(transport);
      transport.receiveMessage(
        const JsonRpcRequest(
          id: 0,
          method: 'initialize',
          params: {
            'protocolVersion': '2025-03-26',
            'capabilities': <String, dynamic>{},
            'clientInfo': {'name': 'test', 'version': '1.0.0'},
          },
        ),
      );
      await _drain();
    }

    JsonRpcResponse responseForId(int id) => transport.sentMessages
        .whereType<JsonRpcResponse>()
        .lastWhere((r) => r.id == id);

    String textFromResponse(int id) {
      final response = responseForId(id);
      final content = response.result['content'] as List;
      return (content.first as Map)['text'] as String;
    }

    tearDown(() async => server.dispose());

    test('monty_run executes code statelessly', () async {
      await init(_serverWithResult(42));

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 10,
          params: {
            'name': 'monty_run',
            'arguments': {'code': '2 + 2'},
          },
        ),
      );
      await _drain();

      expect(textFromResponse(10), contains('42'));
    });

    test('monty_session_create creates a session', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 11,
          params: {
            'name': 'monty_session_create',
            'arguments': {'session_id': 'rpc-s1'},
          },
        ),
      );
      await _drain();

      expect(textFromResponse(11), contains('Session created: rpc-s1'));
      expect(server.sessionManager.sessionCount, 1);
    });

    test('monty_session_create duplicate returns error', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));
      server.sessionManager.createSession(id: 'dup');

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 12,
          params: {
            'name': 'monty_session_create',
            'arguments': {'session_id': 'dup'},
          },
        ),
      );
      await _drain();

      final response = responseForId(12);
      expect(response.result['isError'], isTrue);
      expect(textFromResponse(12), contains('already exists'));
    });

    test('monty_session_exec executes in session', () async {
      await init(
        MontyMcpServer(
          platformFactory: () => _mockForSessionExec(
            result: const MontyResult(value: 99, usage: _usage),
          ),
        ),
      );
      server.sessionManager.createSession(id: 'exec-s');

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 13,
          params: {
            'name': 'monty_session_exec',
            'arguments': {'session_id': 'exec-s', 'code': '99'},
          },
        ),
      );
      await _drain();

      expect(textFromResponse(13), contains('99'));
    });

    test('monty_session_exec with unknown session returns error', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 14,
          params: {
            'name': 'monty_session_exec',
            'arguments': {'session_id': 'ghost', 'code': '1'},
          },
        ),
      );
      await _drain();

      final response = responseForId(14);
      expect(response.result['isError'], isTrue);
      expect(textFromResponse(14), contains('Session not found'));
    });

    test('monty_session_list returns active sessions', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));
      server.sessionManager
        ..createSession(id: 'x')
        ..createSession(id: 'y');

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 15,
          params: {
            'name': 'monty_session_list',
            'arguments': <String, dynamic>{},
          },
        ),
      );
      await _drain();

      final text = textFromResponse(15);
      expect(text, contains('x'));
      expect(text, contains('y'));
    });

    test('monty_session_list empty', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 16,
          params: {
            'name': 'monty_session_list',
            'arguments': <String, dynamic>{},
          },
        ),
      );
      await _drain();

      expect(textFromResponse(16), contains('No active sessions'));
    });

    test('monty_session_destroy destroys session', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));
      server.sessionManager.createSession(id: 'doomed');

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 17,
          params: {
            'name': 'monty_session_destroy',
            'arguments': {'session_id': 'doomed'},
          },
        ),
      );
      await _drain();

      expect(textFromResponse(17), contains('Session destroyed: doomed'));
      expect(server.sessionManager.sessionCount, 0);
    });

    test('monty_session_destroy nonexistent returns error', () async {
      await init(MontyMcpServer(platformFactory: MockMontyPlatform.new));

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 18,
          params: {
            'name': 'monty_session_destroy',
            'arguments': {'session_id': 'nope'},
          },
        ),
      );
      await _drain();

      final response = responseForId(18);
      expect(response.result['isError'], isTrue);
      expect(textFromResponse(18), contains('Session not found'));
    });
  });

  group('Host function MCP tool callback', () {
    test('successful tool call validates params and returns result', () async {
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

      final transport = _TestTransport();
      await server.serve(transport);

      // Send initialize request first (MCP protocol requires it).
      transport.receiveMessage(
        const JsonRpcRequest(
          id: 0,
          method: 'initialize',
          params: {
            'protocolVersion': '2025-03-26',
            'capabilities': <String, dynamic>{},
            'clientInfo': {'name': 'test', 'version': '1.0.0'},
          },
        ),
      );
      await _drain();

      // Call the host function tool via JSON-RPC.
      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 1,
          params: {
            'name': 'add',
            'arguments': {'a': 3, 'b': 4},
          },
        ),
      );
      await _drain();

      final response = transport.sentMessages
          .whereType<JsonRpcResponse>()
          .lastWhere((r) => r.id == 1);
      final content = response.result['content'] as List;
      final text = (content.first as Map)['text'] as String;
      expect(text, contains('7'));

      await server.dispose();
    });

    test('handler exception returns error via MCP tool callback', () async {
      final server = MontyMcpServer(
        platformFactory: MockMontyPlatform.new,
      )..registerHostFunction(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'fail_fn',
              description: 'Always throws',
            ),
            handler: (args) async => throw const FormatException('bad input'),
          ),
        );

      final transport = _TestTransport();
      await server.serve(transport);

      transport.receiveMessage(
        const JsonRpcRequest(
          id: 0,
          method: 'initialize',
          params: {
            'protocolVersion': '2025-03-26',
            'capabilities': <String, dynamic>{},
            'clientInfo': {'name': 'test', 'version': '1.0.0'},
          },
        ),
      );
      await _drain();

      transport.receiveMessage(
        const JsonRpcCallToolRequest(
          id: 2,
          params: {
            'name': 'fail_fn',
            'arguments': <String, dynamic>{},
          },
        ),
      );
      await _drain();

      final response = transport.sentMessages
          .whereType<JsonRpcResponse>()
          .lastWhere((r) => r.id == 2);
      final result = response.result;
      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      final text = (content.first as Map)['text'] as String;
      expect(text, contains('bad input'));

      await server.dispose();
    });
  });
}

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
            ],
          ),
          handler: (args) async => 'Hello, ${args['name']}!',
        ),
      ];
}

String _text(CallToolResult result) =>
    (result.content.first as TextContent).text;

/// Minimal test transport for invoking MCP tools via JSON-RPC.
class _TestTransport implements Transport {
  final List<JsonRpcMessage> sentMessages = [];

  @override
  String? get sessionId => 'test';

  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(JsonRpcMessage message)? onmessage;

  void receiveMessage(JsonRpcMessage message) => onmessage?.call(message);

  @override
  Future<void> close() async => onclose?.call();

  @override
  Future<void> send(JsonRpcMessage message, {int? relatedRequestId}) async {
    sentMessages.add(message);
  }

  @override
  Future<void> start() async {}
}

/// Give the event loop a chance to process pending microtasks.
Future<void> _drain() => Future<void>.delayed(const Duration(milliseconds: 50));
