@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:test/test.dart';

/// Integration tests proving REPL state persistence through real FFI.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/ffi/integration/repl_smoke_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  test('REPL: variable persists across feeds', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    final r1 = await repl.feed('x = 42');
    expect(r1.isError, isFalse);

    final r2 = await repl.feed('x + 1');
    expect(r2.value, const MontyInt(43));

    await repl.dispose();
  });

  test('REPL: function definition persists', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await repl.feed('def greet(name):\n    return f"hello {name}"');
    final r = await repl.feed('greet("world")');

    expect(r.value, const MontyString('hello world'));
    await repl.dispose();
  });

  test('REPL: list mutation persists across feeds', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await repl.feed('items = [1, 2, 3]');
    await repl.feed('items.append(4)');
    final r = await repl.feed('len(items)');

    expect(r.value, const MontyInt(4));
    await repl.dispose();
  });

  test('REPL: survives runtime error', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await repl.feed('x = 10');

    // This should raise but REPL survives.
    expect(
      () => repl.feed('1 / 0'),
      throwsA(isA<MontyScriptError>()),
    );

    // x should still be accessible.
    final r = await repl.feed('x');
    expect(r.value, const MontyInt(10));

    await repl.dispose();
  });

  test('REPL: help() lists host functions', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
      hostFunctions: {
        'fetch': 'HTTP GET request',
        'render': 'Render UI component',
      },
    );

    final r = await repl.feed('help()');
    expect(r.printOutput, contains('fetch()'));
    expect(r.printOutput, contains('HTTP GET request'));
    expect(r.printOutput, contains('render()'));

    await repl.dispose();
  });

  test('REPL: help("name") shows detail', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
      hostFunctions: {'fetch': 'HTTP GET request'},
    );

    final r = await repl.feed("help('fetch')");
    expect(r.printOutput, contains('fetch()'));
    expect(r.printOutput, contains('HTTP GET request'));

    await repl.dispose();
  });

  test('REPL: help("unknown") shows available', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
      hostFunctions: {'fetch': 'HTTP GET request'},
    );

    final r = await repl.feed("help('nope')");
    expect(r.printOutput, contains('Unknown function'));
    expect(r.printOutput, contains('fetch'));

    await repl.dispose();
  });

  test('REPL: print output captured per-feed', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    final r1 = await repl.feed("print('hello')");
    expect(r1.printOutput, 'hello\n');

    final r2 = await repl.feed("print('world')");
    expect(r2.printOutput, 'world\n');

    await repl.dispose();
  });

  test('REPL: multiple independent sessions', () async {
    final a = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );
    final b = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await a.feed('x = 1');
    await b.feed('x = 99');

    final ra = await a.feed('x');
    final rb = await b.feed('x');

    expect(ra.value, const MontyInt(1));
    expect(rb.value, const MontyInt(99));

    await a.dispose();
    await b.dispose();
  });

  test('REPL: closure persists across feeds', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await repl.feed('def make_adder(n):\n    return lambda x: x + n');
    await repl.feed('add5 = make_adder(5)');
    final r = await repl.feed('add5(10)');

    expect(r.value, const MontyInt(15));
    await repl.dispose();
  });

  test('detectContinuation: complete statement', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    final mode = await repl.detectContinuation('x = 1');
    expect(mode, ReplContinuationMode.complete);

    await repl.dispose();
  });

  test('detectContinuation: incomplete block', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    final mode = await repl.detectContinuation('def f():');
    expect(mode, ReplContinuationMode.incompleteBlock);

    await repl.dispose();
  });

  test('detectContinuation: incomplete implicit', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    final mode = await repl.detectContinuation('x = (1 +');
    expect(mode, ReplContinuationMode.incompleteImplicit);

    await repl.dispose();
  });

  test('REPL: 50-iteration stability', () async {
    final repl = MontyRepl.withBindings(
      bindings: FfiReplBindings(bindings: bindings),
    );

    await repl.feed('total = 0');
    for (var i = 1; i <= 50; i++) {
      await repl.feed('total += $i');
    }
    final r = await repl.feed('total');

    // sum of 1..50 = 1275
    expect(r.value, const MontyInt(1275));
    await repl.dispose();
  });
}
