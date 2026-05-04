@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('buildRunScriptFunction', () {
    late MontyRuntime runtime;
    late Map<String, String> vfs;

    setUp(() {
      vfs = {};
      runtime = MontyRuntime()
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

    test('returns last expression from sub-script', () async {
      vfs['greet.py'] = 'f"hello, {name}!"';
      final result = await runtime
          .execute(
            'run_script("greet.py", inputs={"name": "alice"})',
          )
          .result;

      expect(result.error, isNull);
      expect(result.value.dartValue, 'hello, alice!');
    });

    test('sub-script with no inputs still runs', () async {
      vfs['add.py'] = '1 + 2';
      final result = await runtime.execute('run_script("add.py")').result;

      expect(result.error, isNull);
      expect(result.value.dartValue, 3);
    });

    test('multiple inputs are all injected', () async {
      vfs['fmt.py'] = 'f"{say}, {target}!"';
      final result = await runtime
          .execute(
            'run_script("fmt.py", inputs={"say": "hi", "target": "alan"})',
          )
          .result;

      expect(result.value.dartValue, 'hi, alan!');
    });

    test('sub-script error surfaces as Python exception', () async {
      vfs['bad.py'] = '1 / 0';
      final result = await runtime.execute('run_script("bad.py")').result;

      // run_script throws, which Python surfaces as an error result.
      expect(result.isError, isTrue);
    });

    test('missing file surfaces as Python exception', () async {
      final result = await runtime.execute('run_script("missing.py")').result;

      expect(result.isError, isTrue);
    });

    test('return value is usable in caller script', () async {
      vfs['double.py'] = 'n * 2';
      final result = await runtime
          .execute(
            'x = run_script("double.py", inputs={"n": 21})\nx',
          )
          .result;

      expect(result.value.dartValue, 42);
    });

    // Return-value semantics: run_script captures the last expression of
    // the sub-script. Assignment statements yield None (dartValue == null).
    test(
      'sub-script assignment statement yields None — not the assigned value',
      () async {
        vfs['assign.py'] = 'x = 99';
        final result = await runtime.execute('run_script("assign.py")').result;

        expect(result.error, isNull);
        // Assignment is a statement; no last-expression value — run_script
        // returns None.
        expect(result.value.dartValue, isNull);
      },
    );

    test('sub-script module-level return yields the return value', () async {
      // pydantic-monty treats module-level `return` as a valid return.
      vfs['ret.py'] = 'return 99';
      final result = await runtime.execute('run_script("ret.py")').result;

      expect(result.error, isNull);
      expect(result.value.dartValue, 99);
    });

    // Both kwargs and positional forms work for host-function params:
    // run_script("foo.py", inputs={"k":"v"}) and
    // run_script("foo.py", {"k":"v"}) are equivalent — pydantic-monty
    // maps positional args to schema params
    // by index. The kwargs-only contract lives at the *Dart* API level: the
    // `inputs` param is a Dart named parameter with no positional form.
    test('positional dict is equivalent to inputs= kwarg form', () async {
      vfs['greet.py'] = 'f"hello, {name}!"';
      final result = await runtime
          .execute('run_script("greet.py", {"name": "alice"})')
          .result;

      expect(result.error, isNull);
      expect(result.value.dartValue, 'hello, alice!');
    });
  });
}
