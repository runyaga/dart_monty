@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';
import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  group('buildRunScriptFunction', () {
    late MontyRuntime runtime;
    late Map<String, String> vfs;

    setUp(() async {
      vfs = {};
      runtime = (await MontyRuntime.start(pool: pool))
        ..register(
          buildRunScriptFunction((path) async {
            final code = vfs[path];
            if (code == null) throw Exception('file not found: $path');

            return code;
          }),
        );
    });

    tearDown(() async {
      await runtime.dispose();
    });

    test(
      'returns last expression from sub-script',
      () async {
        vfs['greet.py'] = 'f"hello, {name}!"';
        final result = await runtime
            .execute(
              'run_script("greet.py", inputs={"name": "alice"})',
            )
            .result;

        expect(result.dartValue, 'hello, alice!');
      },
    );

    test('sub-script with no inputs still runs', () async {
      vfs['add.py'] = '1 + 2';
      final result = await runtime.execute('run_script("add.py")').result;

      expect(result.dartValue, 3);
    });

    test('multiple inputs are all injected', () async {
      vfs['fmt.py'] = 'f"{say}, {target}!"';
      final result = await runtime
          .execute(
            'run_script("fmt.py", inputs={"say": "hi", "target": "alan"})',
          )
          .result;

      expect(result.dartValue, 'hi, alan!');
    });

    test(
      'sub-script error surfaces as Python exception',
      () async {
        vfs['bad.py'] = '1 / 0';
        await expectLater(
          runtime.execute('run_script("bad.py")').result,
          throwsA(isA<MontyError>()),
        );
      },
    );

    test('a failing sub-script names the path and its message', () async {
      vfs['bad.py'] = 'raise ValueError("no good")';
      final result = await runtime.execute('''
try:
    run_script("bad.py")
    r = None
except Exception as e:
    r = (type(e).__name__, str(e))
r
''').result;

      expect(result.dartValue, [
        'RuntimeError',
        'Exception: run_script("bad.py") failed: no good',
      ]);
    });

    test('a tuple result reaches the caller as a tuple', () async {
      vfs['pair.py'] = '(1, "a")';
      final result = await runtime
          .execute('t = run_script("pair.py")\n(type(t).__name__, t[1])')
          .result;

      expect(result.dartValue, ['tuple', 'a']);
    });

    test("the sub-script cannot see the caller's variables", () async {
      vfs['peek.py'] = 'secret';
      await expectLater(
        runtime.execute('secret = 1\nrun_script("peek.py")').result,
        throwsA(
          isA<MontyError>().having(
            (e) => e.exception.message,
            'message',
            contains('run_script("peek.py") failed'),
          ),
        ),
      );
    });

    test("the sub-script's globals do not leak back", () async {
      vfs['set.py'] = 'leak = 5\nleak';
      final result = await runtime.execute('''
run_script("set.py")
try:
    leak
    r = "leaked"
except NameError:
    r = "isolated"
r
''').result;

      expect(result.dartValue, 'isolated');
    });

    test("the sub-script gets none of the caller's host functions", () async {
      vfs['nested.py'] = 'run_script("nested.py")';
      await expectLater(
        runtime.execute('run_script("nested.py")').result,
        throwsA(
          isA<MontyError>().having(
            (e) => e.exception.message,
            'message',
            allOf(contains('failed'), contains('run_script')),
          ),
        ),
      );
    });

    test('missing file surfaces as Python exception', () async {
      await expectLater(
        runtime.execute('run_script("missing.py")').result,
        throwsA(isA<MontyError>()),
      );
    });

    test(
      'return value is usable in caller script',
      () async {
        vfs['double.py'] = 'n * 2';
        final result = await runtime
            .execute(
              'x = run_script("double.py", inputs={"n": 21})\nx',
            )
            .result;

        expect(result.dartValue, 42);
      },
    );

    // Return-value semantics: run_script captures the last expression of
    // the sub-script. Assignment statements yield None (dartValue == null).
    test(
      'sub-script assignment statement yields None — not the assigned value',
      () async {
        vfs['assign.py'] = 'x = 99';
        final result = await runtime.execute('run_script("assign.py")').result;

        // Assignment is a statement; no last-expression value — run_script
        // returns None.
        expect(result.dartValue, isNull);
      },
    );

    test(
      'sub-script module-level return yields the return value',
      () async {
        // pydantic-monty treats module-level `return` as a valid return.
        vfs['ret.py'] = 'return 99';
        final result = await runtime.execute('run_script("ret.py")').result;

        expect(result.dartValue, 99);
      },
    );

    // Both kwargs and positional forms work for host-function params:
    // run_script("foo.py", inputs={"k":"v"}) and
    // run_script("foo.py", {"k":"v"}) are equivalent — pydantic-monty
    // maps positional args to schema params
    // by index. The kwargs-only contract lives at the *Dart* API level: the
    // `inputs` param is a Dart named parameter with no positional form.
    test(
      'positional dict is equivalent to inputs= kwarg form',
      () async {
        vfs['greet.py'] = 'f"hello, {name}!"';
        final result = await runtime
            .execute('run_script("greet.py", {"name": "alice"})')
            .result;

        expect(result.dartValue, 'hello, alice!');
      },
    );

    // Schema-level validation: HostFunctionSchema.mapAndValidate +
    // HostParam.validate throw FormatException on bad arg shape, which
    // dispatch.dart routes back to Python as a script error.
    group('invalid arguments surface as Python errors', () {
      test('wrong type for path (int instead of str)', () async {
        await expectLater(
          runtime.execute('run_script(123)').result,
          throwsA(isA<MontyError>()),
        );
      });

      test('wrong type for inputs (str instead of dict/map)', () async {
        vfs['greet.py'] = 'f"hi {name}"';
        await expectLater(
          runtime.execute('run_script("greet.py", inputs="oops")').result,
          throwsA(isA<MontyError>()),
        );
      });

      test('missing required path arg', () async {
        await expectLater(
          runtime.execute('run_script()').result,
          throwsA(isA<MontyError>()),
        );
      });

      test('unknown kwarg rejected', () async {
        vfs['greet.py'] = 'f"hi {name}"';
        await expectLater(
          runtime
              .execute('run_script("greet.py", typo={"name": "alice"})')
              .result,
          throwsA(isA<MontyError>()),
        );
      });
    });
  });

  test('a sub-execution waits for a free worker, bounded by the '
      "pool's checkoutTimeout", () async {
    // One worker, held by the runtime: the sub-execution's checkout times
    // out instead of hanging.
    final small = await startTestPool(
      maxProcesses: 1,
      checkoutTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(small.close);
    final runtime = (await MontyRuntime.start(pool: small))
      ..register(buildRunScriptFunction((path) => '1'));
    addTearDown(runtime.dispose);

    await expectLater(
      runtime.execute('run_script("one.py")').result,
      throwsA(
        isA<MontyError>().having(
          (e) => e.exception.message,
          'message',
          contains('TimeoutException'),
        ),
      ),
    );
  });
}
