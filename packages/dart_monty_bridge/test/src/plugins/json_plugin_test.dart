// Tests for the deprecated JsonPlugin — suppressing deprecation warnings.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_bridge/src/plugins/json_plugin.dart';
import 'package:test/test.dart';

void main() {
  late JsonPlugin plugin;

  setUp(() {
    plugin = JsonPlugin();
  });

  HostFunctionHandler findHandler(String name) {
    return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
  }

  group('metadata', () {
    test('namespace is json', () {
      expect(plugin.namespace, 'json');
    });

    test('provides 3 host functions', () {
      expect(plugin.functions, hasLength(3));
    });

    test('systemPromptContext is non-null', () {
      expect(plugin.systemPromptContext, isNotNull);
    });

    test('createChildInstance returns new JsonPlugin', () {
      final child = plugin.createChildInstance();
      expect(child, isA<JsonPlugin>());
      expect(child, isNot(same(plugin)));
    });
  });

  group('json_loads', () {
    test('parses object to Map', () async {
      final handler = findHandler('json_loads');
      final result = await handler({'data': '{"a": 1, "b": "two"}'});
      expect(result, isA<Map<String, Object?>>());
      final map = result! as Map<String, Object?>;
      expect(map['a'], 1);
      expect(map['b'], 'two');
    });

    test('parses array to List', () async {
      final handler = findHandler('json_loads');
      final result = await handler({'data': '[1, 2, 3]'});
      expect(result, isA<List<Object?>>());
      expect(result, [1, 2, 3]);
    });

    test('parses nested structures', () async {
      final handler = findHandler('json_loads');
      final result = await handler({
        'data': '{"items": [{"id": 1}, {"id": 2}]}',
      });
      final map = result! as Map<String, Object?>;
      final items = map['items']! as List<Object?>;
      expect(items, hasLength(2));
      expect((items[0]! as Map<String, Object?>)['id'], 1);
    });

    test('throws FormatException on invalid JSON', () async {
      final handler = findHandler('json_loads');
      expect(
        () => handler({'data': '{not json'}),
        throwsFormatException,
      );
    });

    test('parses primitives', () async {
      final handler = findHandler('json_loads');
      expect(await handler({'data': '"hello"'}), 'hello');
      expect(await handler({'data': '42'}), 42);
      expect(await handler({'data': 'true'}), true);
      expect(await handler({'data': 'null'}), null);
    });

    test('throws FormatException for oversized input', () async {
      final handler = findHandler('json_loads');
      final huge = 'x' * (1024 * 1024 + 1);
      expect(
        () => handler({'data': huge}),
        throwsFormatException,
      );
    });

    test('respects custom maxInputSize', () async {
      final small = JsonPlugin(maxInputSize: 10);
      final handler = small.functions.firstWhere(
        (f) => f.schema.name == 'json_loads',
      );
      expect(
        () => handler.handler({'data': 'x' * 11}),
        throwsFormatException,
      );
    });
  });

  group('json_dumps', () {
    test('serializes Map to compact JSON', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({
        'data': {'a': 1, 'b': 'two'},
        'indent': 0,
      });
      expect(result, '{"a":1,"b":"two"}');
    });

    test('serializes List to compact JSON', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({
        'data': [1, 2, 3],
        'indent': 0,
      });
      expect(result, '[1,2,3]');
    });

    test('pretty-prints with indent > 0', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({
        'data': {'a': 1},
        'indent': 2,
      });
      final pretty = result! as String;
      expect(pretty, contains('\n'));
      expect(pretty, contains('  "a"'));
    });

    test('compact output has no newlines with indent 0', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({
        'data': {
          'a': 1,
          'b': [2, 3],
        },
        'indent': 0,
      });
      final compact = result! as String;
      expect(compact, isNot(contains('\n')));
    });

    test('handles nested structures', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({
        'data': {
          'items': [
            {'id': 1},
          ],
        },
        'indent': 0,
      });
      expect(result, '{"items":[{"id":1}]}');
    });

    test('serializes null', () async {
      final handler = findHandler('json_dumps');
      final result = await handler({'data': null, 'indent': 0});
      expect(result, 'null');
    });
  });

  group('json_get', () {
    test('extracts top-level key', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"name": "E106", "score": 42}',
        'path': 'name',
      });
      expect(result, 'E106');
    });

    test('extracts nested dot-path', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"scores": {"ratio": {"value": 0.149}}}',
        'path': 'scores.ratio.value',
      });
      expect(result, 0.149);
    });

    test('extracts from arrays with integer index', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"items": [{"id": "a"}, {"id": "b"}]}',
        'path': 'items.1.id',
      });
      expect(result, 'b');
    });

    test('returns null for missing path', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"a": 1}',
        'path': 'b.c.d',
      });
      expect(result, isNull);
    });

    test('returns null for path into non-Map', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"a": 42}',
        'path': 'a.b',
      });
      expect(result, isNull);
    });

    test('returns null for out-of-bounds array index', () async {
      final handler = findHandler('json_get');
      final result = await handler({
        'data': '{"items": [1, 2]}',
        'path': 'items.5',
      });
      expect(result, isNull);
    });

    test('throws FormatException on invalid JSON', () async {
      final handler = findHandler('json_get');
      expect(
        () => handler({'data': 'bad', 'path': 'x'}),
        throwsFormatException,
      );
    });
  });
}
