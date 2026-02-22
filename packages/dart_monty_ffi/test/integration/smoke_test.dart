@Tags(['integration'])
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests that require the native Monty library.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_ffi
/// DYLD_LIBRARY_PATH=../../native/target/release dart test --tags=integration
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  test('smoke: run("2+2") returns 4', () async {
    final monty = MontyFfi(bindings: bindings);
    final result = await monty.run('2 + 2');

    expect(result.value, 4);
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
    expect(pending.arguments, ['https://example.com']);

    final done = await monty.resume('response body');
    expect(done, isA<MontyComplete>());
    final complete = done as MontyComplete;
    expect(complete.result.value, 'response body');

    await monty.dispose();
  });

  test('resumeWithError: error propagation', () async {
    final monty = MontyFfi(bindings: bindings);
    final progress = await monty.start(
      'try:\n  result = fetch("url")\nexcept Exception as e:\n  str(e)',
      externalFunctions: ['fetch'],
    );

    expect(progress, isA<MontyPending>());

    final done = await monty.resumeWithError('network failure');
    expect(done, isA<MontyComplete>());
    final complete = done as MontyComplete;
    expect(complete.result.value, contains('network failure'));

    await monty.dispose();
  });

  test('snapshot round-trip', () async {
    final monty = MontyFfi(bindings: bindings);
    final progress = await monty.start(
      'x = 42\nfetch("url")',
      externalFunctions: ['fetch'],
    );
    expect(progress, isA<MontyPending>());

    final data = await monty.snapshot();
    expect(data, isNotEmpty);

    final restored = await monty.restore(data) as MontyFfi;
    final done = await restored.resume('ok');
    expect(done, isA<MontyComplete>());

    await monty.dispose();
    await restored.dispose();
  });

  test('error handling: invalid syntax', () async {
    final monty = MontyFfi(bindings: bindings);

    expect(
      () => monty.run('def'),
      throwsA(isA<MontyException>()),
    );

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

    expect(result.value, 'Hello 🌍🎉');
    await monty.dispose();
  });

  test('multiple instances: no state bleed', () async {
    final a = MontyFfi(bindings: bindings);
    final b = MontyFfi(bindings: bindings);

    final resultA = await a.run('10 + 20');
    final resultB = await b.run('"hello"');

    expect(resultA.value, 30);
    expect(resultB.value, 'hello');

    await a.dispose();
    await b.dispose();
  });

  test('memory stability: 100-iteration loop', () async {
    for (var i = 0; i < 100; i++) {
      final monty = MontyFfi(bindings: bindings);
      final result = await monty.run('$i + 1');
      expect(result.value, i + 1);
      await monty.dispose();
    }
  });
}
