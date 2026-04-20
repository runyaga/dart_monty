// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Native FFI example — run Python from Dart on desktop.
///
/// Prerequisites:
///   cd native && cargo build --release
///
/// Run:
///   dart run bin/main.dart
library;

import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  // ── 1. Simple expression ──────────────────────────────────────────────
  print('── Simple expression ──');
  final runtime = MontyRuntime();
  final r1 = await runtime.execute('2 + 2').result;
  print('  2 + 2 = ${r1.value.dartValue}');

  // ── 2. State persists across calls ───────────────────────────────────
  print('\n── State persistence ──');
  await runtime.execute('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
''').result;
  final r2 = await runtime.execute('fib(10)').result;
  print('  fib(10) = ${r2.value.dartValue}');

  // ── 3. Error handling ─────────────────────────────────────────────────
  print('\n── Error handling ──');
  final r3 = await runtime.execute('1 / 0').result;
  if (r3.isError) {
    print('  Error: ${r3.error!.message}');
  }

  // ── 4. Registered host function ───────────────────────────────────────
  print('\n── Host function ──');
  runtime.register(
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'fetch',
        description: 'Simulated HTTP fetch.',
        params: [HostParam(name: 'url', type: HostParamType.string)],
      ),
      handler: (args, _) async {
        final url = args['url']! as String;
        return '<html>Hello from $url</html>';
      },
    ),
  );
  final r4 = await runtime.execute('fetch("https://example.com")').result;
  print('  fetch() = ${r4.value.dartValue}');

  await runtime.dispose();
  print('\nDone.');
}
