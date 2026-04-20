// G9: HostParam / schema / edge cases.
//
// Covers schema generation, required/optional params, wrong-type args,
// MontyValueX type assertions, and extension introspection.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/schema_experiment_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import '../harness.dart';

void main() {
// ---------------------------------------------------------------------------
// G9-1: Schema generation — schemas + llmSchemas
// ---------------------------------------------------------------------------

group('G9-1: schema generation', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..registerTool(
        'search',
        (a, c) async => [],
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
      ..registerTool('noop', (a, c) async => null);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('schemas contains entries for registered tools', () {
    final names = h.runtime.schemas.map((s) => s.name).toList();
    expect(names, contains('search'));
    expect(names, contains('noop'));
  });

  test('search schema has correct param count', () {
    final schema = h.runtime.schemas.firstWhere((s) => s.name == 'search');
    expect(schema.params, hasLength(2));
  });

  test('required param has isRequired true, optional false', () {
    final schema = h.runtime.schemas.firstWhere((s) => s.name == 'search');
    final query = schema.params.firstWhere((p) => p.name == 'query');
    final limit = schema.params.firstWhere((p) => p.name == 'limit');
    expect(query.isRequired, isTrue);
    expect(limit.isRequired, isFalse);
  });
});

// ---------------------------------------------------------------------------
// G9-2: Wrong param type — Python passes wrong type
// ---------------------------------------------------------------------------

group('G9-2: wrong param type handling', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..registerTool(
        'typed_tool',
        (args, ctx) async {
          final n = args['n'];
          if (n is! int) throw ArgumentError('n must be int, got $n');
          return n * 2;
        },
        params: [
          const HostParam(name: 'n', type: HostParamType.integer),
        ],
      );
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('handler can validate types and throw', () async {
    final (:result, :events) =
        await h.runWithEvents("typed_tool(n='not_a_number')");

    // Python receives the exception as an error string — execution continues.
    // (Per feedback: errors are returned not thrown, so LLM can handle them.)
    expect(result.error, isNotNull);
  });

  test('correct int type passes through cleanly', () async {
    final result = await h.run('typed_tool(n=21)');

    expect(result.error, isNull);
    expect(result.value.dartValue, 42);
  });
});

// ---------------------------------------------------------------------------
// G9-3: Optional params — None default in Python
// ---------------------------------------------------------------------------

group('G9-3: optional params', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..registerTool(
        'greet',
        (args, ctx) async {
          final name = args['name'] as String;
          final lang = args['lang'] as String? ?? 'en';
          return lang == 'es' ? 'Hola, $name!' : 'Hello, $name!';
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

    expect(result.error, isNull);
    expect(result.value.dartValue, 'Hello, Alice!');
  });

  test('passing optional param overrides default', () async {
    final result = await h.run("greet(name='Alice', lang='es')");

    expect(result.error, isNull);
    expect(result.value.dartValue, 'Hola, Alice!');
  });
});

// ---------------------------------------------------------------------------
// G9-4: MontyValue type assertions — dartValue coercions
// ---------------------------------------------------------------------------

group('G9-4: MontyValue types via dartValue', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness();
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('Python int → Dart int', () async {
    final r = await h.run('42');
    expect(r.value.dartValue, isA<int>());
    expect(r.value.dartValue, 42);
  });

  test('Python float → Dart double', () async {
    final r = await h.run('3.14');
    expect(r.value.dartValue, isA<double>());
    expect((r.value.dartValue as double), closeTo(3.14, 0.001));
  });

  test('Python str → Dart String', () async {
    final r = await h.run("'hello'");
    expect(r.value.dartValue, isA<String>());
    expect(r.value.dartValue, 'hello');
  });

  test('Python bool → Dart bool', () async {
    final r = await h.run('True');
    expect(r.value.dartValue, isA<bool>());
    expect(r.value.dartValue, true);
  });

  test('Python list → Dart List', () async {
    final r = await h.run('[1, 2, 3]');
    expect(r.value.dartValue, isA<List<Object?>>());
    expect(r.value.dartValue, [1, 2, 3]);
  });

  test('Python dict → Dart Map', () async {
    final r = await h.run("{'key': 'value', 'n': 7}");
    expect(r.value.dartValue, isA<Map<String, Object?>>());
    final m = r.value.dartValue as Map<String, Object?>;
    expect(m['key'], 'value');
    expect(m['n'], 7);
  });

  test('Python None → Dart null', () async {
    final r = await h.run('None');
    expect(r.value.dartValue, isNull);
  });

  test('Python nested structure round-trips cleanly', () async {
    final r = await h.run("[{'x': 1}, {'x': 2}]");
    final list = r.value.dartValue as List;
    expect(list.first, {'x': 1});
    expect(list.last, {'x': 2});
  });
});
} // end main
