// Standalone browser walkthrough: printing is the visible demo output.
// ignore_for_file: avoid_print
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show ExternalReturnValue, FunctionSnapshot, MontyComplete;
import 'package:web_example/demo_examples.dart';
import 'package:web_example/demo_pool.dart';

/// Runs the original expression, function, string, error and resume examples.
Future<void> runBridgeWalkthrough() async {
  print('=== dart_monty Web Example ===');
  final examples = await loadDemoExamples();
  final pool = await startDemoPool();
  print('Worker initialized.');
  try {
    await pool.withSession(
      (session) => _examples(session, examples),
    );
  } finally {
    await pool.close();
  }
  print('=== All examples complete ===');
  print('EXAMPLE_DONE');
}

Future<void> _examples(
  MontySession session,
  Map<String, Map<String, dynamic>> examples,
) async {
  // ── 1. Simple expression ──────────────────────────────────────────────
  print('');
  print('── Simple expression ──');
  final sum = await session
      .feedRun(examples['bridge-walkthrough-5']!['code'] as String);
  print('  2 + 2 = ${sum.dartValue}');

  // ── 2. Multi-line code ────────────────────────────────────────────────
  print('');
  print('── Multi-line code ──');
  final fib = await session
      .feedRun(examples['bridge-walkthrough-4']!['code'] as String);
  print('  fib(10) = ${fib.dartValue}');

  // ── 3. String result ──────────────────────────────────────────────────
  print('');
  print('── String result ──');
  final hello = await session
      .feedRun(examples['bridge-walkthrough-3']!['code'] as String);
  print('  "hello " * 3 = ${hello.dartValue}');

  // ── 4. Error handling ─────────────────────────────────────────────────
  print('');
  print('── Error handling ──');
  try {
    await session.feedRun(examples['bridge-walkthrough-2']!['code'] as String);
  } on MontyError catch (e) {
    print('  1/0 → error: ${e.exception.excType}: ${e.exception.message}');
  }

  // ── 5. Iterative execution ────────────────────────────────────────────
  print('');
  print('── Iterative execution ──');
  var snapshot = await session
      .feedStart(examples['bridge-walkthrough-1']!['code'] as String);
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
  snapshot = await session
      .feedStart(examples['bridge-walkthrough-0']!['code'] as String);
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
