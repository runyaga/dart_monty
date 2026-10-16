// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Web example — run Python from Dart in the browser.
///
/// This is a standalone Dart script compiled to JS, not a package:test file.
/// Python runs in dart_monty_core's Web Worker; the demo drives one session
/// with `feedRun`, and steps through host calls with `feedStart`.
///
/// Build & run:
///   bash run.sh
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show ExternalReturnValue, FunctionSnapshot, MontyComplete, MontyString;

import 'package:web_example/demo_pool.dart';
import 'package:web_example/demo_ready.dart';

Future<void> main() async {
  print('=== dart_monty Web Example ===');
  print('');

  final Monty pool;
  try {
    pool = await startDemoPool();
  } on Object catch (e) {
    print('ERROR: Failed to start the Monty worker: $e');
    print('EXAMPLE_DONE');
    montyDemoFailed('main', 'Monty.start failed: $e');

    return;
  }
  print('Worker initialized.');

  try {
    await pool.withSession(_examples);
  } on Object catch (e) {
    print('ERROR: $e');
    montyDemoFailed('main', '$e');

    return;
  } finally {
    await pool.close();
  }

  print('');
  print('=== All examples complete ===');
  print('EXAMPLE_DONE');
  // Raised only after every example above has actually run, so the gate's
  // green means "this demo executed Python in the browser", not "the script
  // parsed".
  montyDemoReady('main');
}

Future<void> _examples(MontySession session) async {
  // ── 1. Simple expression ──────────────────────────────────────────────
  print('');
  print('── Simple expression ──');
  final sum = await session.feedRun('2 + 2');
  print('  2 + 2 = ${sum.dartValue}');

  // ── 2. Multi-line code ────────────────────────────────────────────────
  print('');
  print('── Multi-line code ──');
  final fib = await session.feedRun('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
fib(10)
''');
  print('  fib(10) = ${fib.dartValue}');

  // ── 3. String result ──────────────────────────────────────────────────
  print('');
  print('── String result ──');
  final hello = await session.feedRun('"hello " * 3');
  print('  "hello " * 3 = ${hello.dartValue}');

  // ── 4. Error handling ─────────────────────────────────────────────────
  print('');
  print('── Error handling ──');
  try {
    await session.feedRun('1 / 0');
  } on MontyError catch (e) {
    print('  1/0 → error: ${e.exception.excType}: ${e.exception.message}');
  }

  // ── 5. Iterative execution ────────────────────────────────────────────
  print('');
  print('── Iterative execution ──');
  var snapshot = await session.feedStart('fetch("https://example.com")');
  if (snapshot is FunctionSnapshot) {
    print('  feedStart() → suspended on ${snapshot.functionName}');
    snapshot = await snapshot.resume(
      const ExternalReturnValue(MontyString('<html>Hello from Dart!</html>')),
    );
  }
  if (snapshot is MontyComplete) {
    print('  resume() → complete, value=${snapshot.output.dartValue}');
  }

  // ── 6. Error injection ────────────────────────────────────────────────
  print('');
  print('── Error injection ──');
  snapshot = await session.feedStart('''
try:
    data = fetch("https://fail.example.com")
except Exception as e:
    result = f"caught: {e}"
result
''');
  if (snapshot is FunctionSnapshot) {
    print('  feedStart() → suspended on ${snapshot.functionName}');
    snapshot = await snapshot.resume(
      const ExternalException('RuntimeError', 'network timeout'),
    );
  }
  if (snapshot is MontyComplete) {
    print('  resume(ExternalException) → value=${snapshot.output.dartValue}');
  }
}
