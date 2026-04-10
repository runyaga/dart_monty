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

      Future<String> callHelp(String name) async {
        final fns = buildIntrospectionFunctions(schemas);
        final helpFn = fns.firstWhere((f) => f.schema.name == 'help');
        final result = await helpFn.handler({'name': name});
        return result! as String;
      }

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

      test('introspection builtins resolve by exact name', () async {
        final result = await callHelp('list_functions');
        final decoded = jsonDecode(result) as Map<String, Object?>;

        expect(decoded['name'], 'list_functions');
      });

      test('introspection builtins resolve by exact name (help)', () async {
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
    });

    group('list_functions', () {
      test('output unchanged with new help behavior', () async {
        final schemas = {
          'math': [
            const HostFunctionSchema(
              name: 'math_add',
              description: 'Add numbers.',
            ),
          ],
        };

        final fns = buildIntrospectionFunctions(schemas);
        final listFn = fns.firstWhere((f) => f.schema.name == 'list_functions');
        final result = await listFn.handler({});
        final decoded = jsonDecode(result! as String) as Map<String, Object?>;
        final tools = decoded['tools']! as Map<String, Object?>;

        expect(tools, contains('math'));
        expect(tools, contains('introspection'));

        final mathTools = tools['math']! as List<Object?>;
        expect(mathTools, hasLength(1));
        final mathAdd = mathTools.first! as Map<String, Object?>;
        expect(mathAdd['name'], 'math_add');
      });
    });
  });
}
