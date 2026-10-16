// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Native example — run Python from Dart on desktop.
///
/// Python runs in core's native worker process, found by core's discovery
/// or named by DART_MONTY_WORKER.
///
/// Run:
///   dart run bin/main.dart
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final worker = Platform.environment['DART_MONTY_WORKER'];
  final pool = await Monty.start(
    workerLocation: worker == null || worker.isEmpty ? null : worker,
  );
  final runtime = await MontyRuntime.start(pool: pool);
  try {
    // ── 1. Simple expression ────────────────────────────────────────────
    print('── Simple expression ──');
    final r1 = await runtime.execute('2 + 2').result;
    print('  2 + 2 = ${r1.dartValue}');

    // ── 2. State persists across calls ─────────────────────────────────
    print('\n── State persistence ──');
    await runtime.execute('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
''').result;
    final r2 = await runtime.execute('fib(10)').result;
    print('  fib(10) = ${r2.dartValue}');

    // ── 3. Error handling ───────────────────────────────────────────────
    // A Python exception fails the result with a MontyError.
    print('\n── Error handling ──');
    try {
      await runtime.execute('1 / 0').result;
    } on MontyError catch (e) {
      print('  Error: ${e.exception.excType}: ${e.exception.message}');
    }

    // ── 4. Registered host function ─────────────────────────────────────
    print('\n── Host function ──');
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'fetch',
          description: 'Simulated HTTP fetch.',
          params: [HostParam(name: 'url', type: HostParamType.string)],
        ),
        handler: (args, _) async {
          final url = (args['url']! as MontyString).value;

          return MontyString('<html>Hello from $url</html>');
        },
      ),
    );
    final r4 = await runtime.execute('fetch("https://example.com")').result;
    print('  fetch() = ${r4.dartValue}');
  } finally {
    await runtime.dispose();
    await pool.close();
  }
  print('\nDone.');
}
