import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/introspection_functions.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:test/test.dart';

final _testCtx = HostContext(emit: (_) {}, executionId: 'test');

void main() {
  group('buildIntrospectionFunctions', () {
    group('help', () {
      late _FakeBridge bridge;

      setUp(() {
        bridge = _FakeBridge()
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'storage_get',
                description: 'Get a value from storage.',
                params: [
                  HostParam(
                    name: 'key',
                    type: HostParamType.string,
                    description: 'The key.',
                  ),
                ],
              ),
              handler: (_, _) async => null,
            ),
            category: 'storage',
          )
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'storage_set',
                description: 'Set a value in storage.',
              ),
              handler: (_, _) async => null,
            ),
            category: 'storage',
          )
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'cache_get',
                description: 'Get a value from cache.',
              ),
              handler: (_, _) async => null,
            ),
            category: 'cache',
          )
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'cache_clear',
                description: 'Clear the cache.',
              ),
              handler: (_, _) async => null,
            ),
            category: 'cache',
          );
        // Register introspection builtins so help can find itself.
        for (final fn in buildIntrospectionFunctions(bridge)) {
          bridge.register(fn, category: 'introspection');
        }
      });

      Future<String> callHelp([String? name]) async {
        final fns = buildIntrospectionFunctions(bridge);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');
        final result = await helpFn.handler!({'name': name}, _testCtx);
        return result! as String;
      }

      test('no args returns full function listing', () async {
        final result = await callHelp();
        final decoded = jsonDecode(result) as Map<String, Object?>;
        final tools = decoded['tools']! as Map<String, Object?>;

        expect(tools, contains('storage'));
        expect(tools, contains('cache'));
        expect(tools, contains('introspection'));

        final storageTools = tools['storage']! as List<Object?>;
        expect(storageTools, hasLength(2));
      });

      test('no args includes introspection with only help', () async {
        final result = await callHelp();
        final decoded = jsonDecode(result) as Map<String, Object?>;
        final tools = decoded['tools']! as Map<String, Object?>;
        final introTools = tools['introspection']! as List<Object?>;

        expect(introTools, hasLength(1));
        final helpTool = introTools.first! as Map<String, Object?>;
        expect(helpTool['name'], 'help');
      });

      test('no args includes params in function schemas', () async {
        final result = await callHelp();
        final decoded = jsonDecode(result) as Map<String, Object?>;
        final tools = decoded['tools']! as Map<String, Object?>;
        final storageTools = tools['storage']! as List<Object?>;
        final storageGet = storageTools.first! as Map<String, Object?>;

        expect(storageGet['name'], 'storage_get');
        final params = storageGet['params']! as List<Object?>;
        expect(params, hasLength(1));
        final param = params.first! as Map<String, Object?>;
        expect(param['name'], 'key');
        expect(param['type'], 'string');
      });

      test('exact match with fully-qualified name', () async {
        final result = await callHelp('storage_get');
        final decoded = jsonDecode(result) as Map<String, Object?>;

        expect(decoded['name'], 'storage_get');
        expect(decoded['description'], 'Get a value from storage.');
      });

      test('exact match returns full schema with params', () async {
        final result = await callHelp('storage_get');
        final decoded = jsonDecode(result) as Map<String, Object?>;
        final params = decoded['params']! as List<Object?>;

        expect(params, hasLength(1));
        final param = params.first! as Map<String, Object?>;
        expect(param['name'], 'key');
        expect(param['type'], 'string');
      });

      test('bare name resolves when unambiguous', () async {
        final result = await callHelp('clear');
        final decoded = jsonDecode(result) as Map<String, Object?>;

        expect(decoded['name'], 'cache_clear');
        expect(decoded['description'], 'Clear the cache.');
      });

      test('bare name returns disambiguation when ambiguous', () async {
        final result = await callHelp('get');
        final decoded = jsonDecode(result) as Map<String, Object?>;

        expect(decoded['error'], 'ambiguous');
        expect(decoded['message'], contains('Multiple functions match "get"'));
        final candidates = decoded['candidates']! as List<Object?>;
        expect(candidates, containsAll(['cache_get', 'storage_get']));
      });

      test('disambiguation candidates are sorted', () async {
        final result = await callHelp('get');
        final decoded = jsonDecode(result) as Map<String, Object?>;
        final candidates = decoded['candidates']! as List<Object?>;

        expect(candidates, ['cache_get', 'storage_get']);
      });

      test(
        'fully-qualified name still works when bare would be ambiguous',
        () async {
          final result = await callHelp('storage_get');
          final decoded = jsonDecode(result) as Map<String, Object?>;

          expect(decoded['name'], 'storage_get');
        },
      );

      test('unknown bare name returns error string', () async {
        final result = await callHelp('nonexistent');

        expect(result, 'Unknown function: nonexistent');
      });

      test('help resolves itself by exact name', () async {
        final result = await callHelp('help');
        final decoded = jsonDecode(result) as Map<String, Object?>;

        expect(decoded['name'], 'help');
      });

      test('bare name resolves with underscore namespace', () async {
        final b = _FakeBridge()
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'db_utils_query',
                description: 'Run a DB query.',
              ),
              handler: (_, _) async => null,
            ),
            category: 'db_utils',
          );
        final fns = buildIntrospectionFunctions(b);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');
        final result = await helpFn.handler!({'name': 'query'}, _testCtx);
        final decoded = jsonDecode(result! as String) as Map<String, Object?>;

        expect(decoded['name'], 'db_utils_query');
      });

      test('only one function is registered (no list_functions)', () {
        final fns = buildIntrospectionFunctions(bridge);

        expect(fns, hasLength(1));
        expect(fns.first.schema.name, 'help');
      });
    });

    group('live introspection', () {
      test(
        'function registered after buildIntrospectionFunctions is visible',
        () async {
          final bridge = _FakeBridge();
          // Build introspection FIRST.
          final fns = buildIntrospectionFunctions(bridge);
          final helpFn = fns.firstWhere((f) => f.schema.name == 'help');

          // Register a function AFTER.
          bridge.register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'late_fn',
                description: 'Registered late.',
              ),
              handler: (_, _) async => null,
            ),
            category: 'late',
          );

          final result = await helpFn.handler!({'name': 'late_fn'}, _testCtx);
          final decoded = jsonDecode(result! as String) as Map<String, Object?>;

          expect(decoded['name'], 'late_fn');
          expect(decoded['description'], 'Registered late.');
        },
      );

      test('late-registered function appears in no-arg listing', () async {
        final bridge = _FakeBridge();
        final fns = buildIntrospectionFunctions(bridge);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');

        // Register after.
        bridge.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'late_fn',
              description: 'Registered late.',
            ),
            handler: (_, _) async => null,
          ),
          category: 'late',
        );

        final result = await helpFn.handler!({}, _testCtx);
        final decoded = jsonDecode(result! as String) as Map<String, Object?>;
        final tools = decoded['tools']! as Map<String, Object?>;

        expect(tools, contains('late'));
      });
    });
  });
}

/// Minimal fake bridge that tracks registered functions and categories.
class _FakeBridge implements MontyBridge {
  final Map<String, HostFunction> _functions = {};
  final Map<String, Set<String>> _categoryIndex = {};

  @override
  BridgeLogger get logger => const NullBridgeLogger();

  @override
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  @override
  List<HostFunctionSchema> get exposedSchemas => const [];

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory {
    final result = <String, List<HostFunctionSchema>>{};
    for (final entry in _categoryIndex.entries) {
      final schemas = <HostFunctionSchema>[];
      for (final name in entry.value) {
        final fn = _functions[name];
        if (fn != null) schemas.add(fn.schema);
      }
      if (schemas.isNotEmpty) result[entry.key] = schemas;
    }
    return result;
  }

  @override
  void register(HostFunction function, {String? category}) {
    final name = function.schema.name;
    _functions[name] = function;
    final cat = category ?? 'uncategorized';
    (_categoryIndex[cat] ??= {}).add(name);
  }

  @override
  void unregister(String name) {
    _functions.remove(name);
  }

  @override
  void registerOs(OsCallHandler handler) {}

  @override
  Stream<BridgeEvent> execute(String code) => const Stream.empty();

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args,
  ) => throw UnimplementedError();

  @override
  void dispose() {}
}
