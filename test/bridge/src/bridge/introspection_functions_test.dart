import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/introspection_functions.dart';
import 'package:test/test.dart';

void main() {
  group('buildIntrospectionFunctions', () {
    group('help', () {
      late Map<String, List<HostFunctionSchema>> schemas;

      setUp(() {
        schemas = {
          'storage': [
            const HostFunctionSchema(
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
            const HostFunctionSchema(
              name: 'storage_set',
              description: 'Set a value in storage.',
            ),
          ],
          'cache': [
            const HostFunctionSchema(
              name: 'cache_get',
              description: 'Get a value from cache.',
            ),
            const HostFunctionSchema(
              name: 'cache_clear',
              description: 'Clear the cache.',
            ),
          ],
        };
      });

      Future<String> callHelp([String? name]) async {
        final fns = buildIntrospectionFunctions(schemas);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');
        final result = await helpFn.handler({'name': name});
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
        final underscoreSchemas = {
          'db_utils': [
            const HostFunctionSchema(
              name: 'db_utils_query',
              description: 'Run a DB query.',
            ),
          ],
        };
        final fns = buildIntrospectionFunctions(underscoreSchemas);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');
        final result = await helpFn.handler({'name': 'query'});
        final decoded = jsonDecode(result! as String) as Map<String, Object?>;

        expect(decoded['name'], 'db_utils_query');
      });

      test('only one function is registered (no list_functions)', () {
        final fns = buildIntrospectionFunctions(schemas);

        expect(fns, hasLength(1));
        expect(fns.first.schema.name, 'help');
      });
    });
  });
}
