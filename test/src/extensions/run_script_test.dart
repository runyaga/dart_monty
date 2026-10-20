import 'package:dart_monty/dart_monty.dart';

import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

/// A real [MontyError] raising [excType] with [message], from a scripted
/// session (the errors have no public constructor).
Future<MontyError> _errorOf(String excType, String message) async {
  final fake = FakeMontySession()..willRaise(excType, message: message);
  try {
    await fake.feedRun('raise');
  } on MontyError catch (e) {
    return e;
  } finally {
    await fake.close();
  }
  throw StateError('the scripted feed did not raise');
}

/// A context whose sub-executor records its calls and answers with
/// [answer].
HostContext _ctx(
  List<(String, Map<String, Object?>?)> calls, {
  Future<MontyValue> Function()? answer,
}) => HostContext(
  emit: (_) {
    // Not used by these tests.
  },
  executionId: 'test',
  subExecute: (code, {inputs}) {
    calls.add((code, inputs));

    return answer?.call() ?? Future.value(const MontyInt(7));
  },
);

void main() {
  final fn = buildRunScriptFunction((path) => 'source of $path');

  test('is run_script(path: string, inputs: map = optional)', () {
    expect(fn.schema.name, 'run_script');
    expect(fn.dispatch, DispatchMode.sync);
    final [path, inputs] = fn.schema.params;
    expect(
      (path.name, path.type, path.isRequired),
      ('path', HostParamType.string, true),
    );
    expect(
      (inputs.name, inputs.type, inputs.isRequired),
      ('inputs', HostParamType.map, false),
    );
  });

  test('runs what readFile returns through subExecute, with inputs', () async {
    final calls = <(String, Map<String, Object?>?)>[];

    final value = await fn.handler!({
      'path': const MontyString('a.py'),
      'inputs': MontyValue.fromDart({'n': 1}),
    }, _ctx(calls));

    final [call] = calls;
    expect(call.$1, 'source of a.py');
    expect(call.$2, {'n': const MontyInt(1)});
    expect(value, const MontyInt(7));
  });

  test('returns the MontyValue as it is', () async {
    const tuple = MontyTuple([MontyInt(1), MontyInt(2)]);

    final value = await fn.handler!(
      {'path': const MontyString('a.py')},
      _ctx([], answer: () async => tuple),
    );

    expect(value, same(tuple));
  });

  test('passes null inputs when none are given', () async {
    final calls = <(String, Map<String, Object?>?)>[];

    await fn.handler!({'path': const MontyString('a.py')}, _ctx(calls));

    final [call] = calls;
    expect(call.$2, isNull);
  });

  test('fails with StateError without a subExecute', () async {
    final bare = HostContext(
      emit: (_) {
        // Not used by this test.
      },
      executionId: 'test',
    );

    await expectLater(
      fn.handler!({'path': const MontyString('a.py')}, bare),
      throwsA(isA<StateError>()),
    );
  });

  test('a readFile failure names the path and the error', () async {
    final failing = buildRunScriptFunction(
      (path) => throw const FormatException('gone'),
    );

    await expectLater(
      failing.handler!({'path': const MontyString('x.py')}, _ctx([])),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'text',
          'Exception: run_script: could not read "x.py": '
              'FormatException: gone',
        ),
      ),
    );
  });

  test("a failing sub-script names the path and the error's message", () async {
    final error = await _errorOf('ValueError', 'no good');

    await expectLater(
      fn.handler!({
        'path': const MontyString('x.py'),
      }, _ctx([], answer: () => Future.error(error))),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'text',
          'Exception: run_script("x.py") failed: no good',
        ),
      ),
    );
  });
}
