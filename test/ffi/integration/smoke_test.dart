@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty/src/ffi/monty_ffi.dart';
import 'package:dart_monty/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

/// Integration tests that require the native Monty library.
///
/// Run with:
/// ```bash
/// cd packages/dart_monty_ffi
/// dart test --run-skipped --tags=integration
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  test('smoke: run("2+2") returns 4', () async {
    final monty = MontyFfi(bindings: bindings);
    final result = await monty.run('2 + 2');

    expect(result.value, const MontyInt(4));
    expect(result.isError, isFalse);
    final usage = result.usage;
    final nonNegative = greaterThanOrEqualTo(0);
    expect(usage.memoryBytesUsed, nonNegative);
    expect(usage.timeElapsedMs, nonNegative);
    expect(usage.stackDepthUsed, nonNegative);

    await monty.dispose();
  });

  test('iterative: start with ext fn, resume, complete', () async {
    final monty = MontyFfi(bindings: bindings);
    final progress = await monty.start(
      'result = fetch("https://example.com")\nresult',
      externalFunctions: ['fetch'],
    );

    expect(progress, isA<MontyPending>());
    final pending = progress as MontyPending;
    expect(pending.functionName, 'fetch');
    expect(pending.arguments, [const MontyString('https://example.com')]);

    final done = await monty.resume('response body');
    expect(done, isA<MontyComplete>());
    final complete = done as MontyComplete;
    expect(complete.result.value, const MontyString('response body'));

    await monty.dispose();
  });

  test('resumeWithError: error propagation', () async {
    final monty = MontyFfi(bindings: bindings);
    final progress = await monty.start(
      'try:\n  result = fetch("url")\n'
      'except Exception as e:\n  result = str(e)\nresult',
      externalFunctions: ['fetch'],
    );

    expect(progress, isA<MontyPending>());

    final done = await monty.resumeWithError('network failure');
    expect(done, isA<MontyComplete>());
    final complete = done as MontyComplete;
    expect(complete.result.value?.dartValue, contains('network failure'));

    await monty.dispose();
  });

  test('error handling: invalid syntax', () async {
    final monty = MontyFfi(bindings: bindings);

    expect(() => monty.run('def'), throwsA(isA<MontyScriptError>()));

    await monty.dispose();
  });

  test('dispose safety: double dispose', () async {
    final monty = MontyFfi(bindings: bindings);
    await monty.run('1');

    await monty.dispose();
    await monty.dispose();
  });

  test('UTF-8 boundaries: emoji round-trip', () async {
    final monty = MontyFfi(bindings: bindings);
    final result = await monty.run('"Hello 🌍🎉"');

    expect(result.value, const MontyString('Hello 🌍🎉'));
    await monty.dispose();
  });

  test('multiple instances: no state bleed', () async {
    final a = MontyFfi(bindings: bindings);
    final b = MontyFfi(bindings: bindings);

    final resultA = await a.run('10 + 20');
    final resultB = await b.run('"hello"');

    expect(resultA.value, const MontyInt(30));
    expect(resultB.value, const MontyString('hello'));

    await a.dispose();
    await b.dispose();
  });

  test('memory stability: 100-iteration loop', () async {
    for (var i = 0; i < 100; i++) {
      final monty = MontyFfi(bindings: bindings);
      final result = await monty.run('$i + 1');
      expect(result.value, MontyInt(i + 1));
      await monty.dispose();
    }
  });
}
