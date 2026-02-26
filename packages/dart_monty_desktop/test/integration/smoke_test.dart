@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_desktop/dart_monty_desktop.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests that require the native Monty library.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_desktop
/// dart test --tags=integration
/// ```
void main() {
  final libPath = _resolveLibraryPath();

  MontyDesktop createMonty() =>
      MontyDesktop(bindings: DesktopBindingsIsolate(libraryPath: libPath));

  test('smoke: run("2+2") returns 4', () async {
    final monty = createMonty();
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
    final monty = createMonty();
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
    final monty = createMonty();
    final code = [
      'try:',
      '  result = fetch("url")',
      'except Exception as e:',
      '  result = str(e)',
      'result',
    ].join('\n');
    final progress = await monty.start(
      code,
      externalFunctions: ['fetch'],
    );

    expect(progress, isA<MontyPending>());

    final done = await monty.resumeWithError('network failure');
    expect(done, isA<MontyComplete>());
    final complete = done as MontyComplete;
    expect(complete.result.value, contains('network failure'));

    await monty.dispose();
  });

  // Snapshot round-trip: skipped — monty_snapshot returns null in current
  // native build (same issue in dart_monty_ffi). Re-enable when upstream
  // snapshot support is available.

  test('error handling: invalid syntax', () async {
    final monty = createMonty();

    expect(
      () => monty.run('def'),
      throwsA(isA<MontyException>()),
    );

    await monty.dispose();
  });

  test('dispose safety: double dispose', () async {
    final monty = createMonty();
    await monty.run('1');

    await monty.dispose();
    await monty.dispose();
  });

  test('UTF-8 boundaries: emoji round-trip', () async {
    final monty = createMonty();
    final result = await monty.run('"Hello 🌍🎉"');

    expect(result.value, 'Hello 🌍🎉');
    await monty.dispose();
  });

  test('multiple instances: no state bleed', () async {
    final a = createMonty();
    final b = createMonty();

    final resultA = await a.run('10 + 20');
    final resultB = await b.run('"hello"');

    expect(resultA.value, 30);
    expect(resultB.value, 'hello');

    await a.dispose();
    await b.dispose();
  });
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';

  return '../../native/target/release/libdart_monty_native.$ext';
}
