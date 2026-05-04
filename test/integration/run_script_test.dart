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
  });
}
