// HostParam / schema / edge cases.
//
// Covers schema generation, required/optional params, wrong-type args,
// MontyValueX type assertions, and extension introspection.
//
// Run with:
//   dart test --tags=integration \
//     test/integration/host_function_schema_test.dart
@Tags(['integration'])
library;

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_monty_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Schema generation.
  // ---------------------------------------------------------------------------

  group('schema generation', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'search',
          (a, c) async => MontyValue.fromDart([]),
          description: 'Search for items',
          params: [
            const HostParam(
              name: 'query',
              type: HostParamType.string,
              description: 'Search query',
            ),
            const HostParam(
              name: 'limit',
              type: HostParamType.integer,
              isRequired: false,
              description: 'Max results',
            ),
          ],
        )
        ..registerTool('noop', (a, c) async => const MontyNone());
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('schemas contains entries for registered tools', () {
      final names = h.runtime.schemas.map((s) => s.name).toList();
      expect(names, contains('search'));
      expect(names, contains('noop'));
    });

    test('search schema has correct param count', () {
      final schema = h.runtime.schemas.firstWhereOrNull(
        (s) => s.name == 'search',
      );
      expect(schema, isNotNull);
      expect(schema?.params, hasLength(2));
    });

    test('required param has isRequired true, optional false', () {
      final schema = h.runtime.schemas.firstWhereOrNull(
        (s) => s.name == 'search',
      );
      final query = schema?.params.firstWhereOrNull((p) => p.name == 'query');
      final limit = schema?.params.firstWhereOrNull((p) => p.name == 'limit');
      expect(query?.isRequired, isTrue);
      expect(limit?.isRequired, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Wrong parameter type handling.
  // ---------------------------------------------------------------------------

  group('wrong param type handling', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'typed_tool',
          (args, ctx) async {
            final n = args['n']!.dartValue;
            if (n is! int) throw ArgumentError('n must be int, got $n');

            return MontyInt(n * 2);
          },
          params: [
            const HostParam(name: 'n', type: HostParamType.integer),
          ],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('handler can validate types and throw', () async {
      // Python receives the exception as an error — the run fails with it.
      await expectLater(
        h.run("typed_tool(n='not_a_number')"),
        throwsA(isA<MontyError>()),
      );
    });

    test('correct int type passes through cleanly', () async {
      final result = await h.run('typed_tool(n=21)');

      expect(result.dartValue, 42);
    });

    test('unknown kwarg raises error — schema rejects it', () async {
      // F9 regression guard: removing the unknown-kwarg check in
      // HostFunctionSchema.mapAndValidate() would make this pass silently.
      await expectLater(
        h.run("typed_tool(n=1, surprise='x')"),
        throwsA(isA<MontyError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Optional parameters.
  // ---------------------------------------------------------------------------

  group('optional params', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'greet',
          (args, ctx) async {
            final name = (args['name']! as MontyString).value;
            final lang = args['lang']!.dartValue as String? ?? 'en';

            return MontyValue.fromDart(
              lang == 'es' ? 'Hola, $name!' : 'Hello, $name!',
            );
          },
          params: [
            const HostParam(name: 'name', type: HostParamType.string),
            const HostParam(
              name: 'lang',
              type: HostParamType.string,
              isRequired: false,
            ),
          ],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('omitting optional param uses Dart-side default', () async {
      final result = await h.run("greet(name='Alice')");

      expect(result.dartValue, 'Hello, Alice!');
    });

    test('passing optional param overrides default', () async {
      final result = await h.run("greet(name='Alice', lang='es')");

      expect(result.dartValue, 'Hola, Alice!');
    });
  });

  // ---------------------------------------------------------------------------
  // MontyValue types via dartValue.
  // ---------------------------------------------------------------------------

  group('MontyValue types via dartValue', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness();
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python int → Dart int', () async {
      final r = await h.run('42');
      expect(r.dartValue, isA<int>());
      expect(r.dartValue, 42);
    });

    test('Python float → Dart double', () async {
      final r = await h.run('3.14');
      expect(r.dartValue, isA<double>());
      expect(r.dartValue! as double, closeTo(3.14, 0.001));
    });

    test('Python str → Dart String', () async {
      final r = await h.run("'hello'");
      expect(r.dartValue, isA<String>());
      expect(r.dartValue, 'hello');
    });

    test('Python bool → Dart bool', () async {
      final r = await h.run('True');
      expect(r.dartValue, isA<bool>());
      expect(r.dartValue, true);
    });

    test('Python list → Dart List', () async {
      final r = await h.run('[1, 2, 3]');
      expect(r.dartValue, isA<List<Object?>>());
      expect(r.dartValue, [1, 2, 3]);
    });

    test('Python dict → Dart Map', () async {
      final r = await h.run("{'key': 'value', 'n': 7}");
      expect(r.dartValue, isA<Map<String, Object?>>());
      final m = r.dartValue! as Map<Object?, Object?>;
      expect(m['key'], 'value');
      expect(m['n'], 7);
    });

    test('Python None → Dart null', () async {
      final r = await h.run('None');
      expect(r.dartValue, isNull);
    });

    test('Python nested structure round-trips cleanly', () async {
      final r = await h.run("[{'x': 1}, {'x': 2}]");
      final list = r.dartValue! as List;
      expect(list.firstOrNull, {'x': 1});
      expect(list.lastOrNull, {'x': 2});
    });
  });
} // end main
