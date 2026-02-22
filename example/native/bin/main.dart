/// Native FFI example — run Python from Dart on desktop.
///
/// Prerequisites:
///   cd native && cargo build --release
///
/// Run:
///   DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///     dart run bin/main.dart
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

Future<void> main() async {
  final monty = MontyFfi(bindings: NativeBindingsFfi());

  // ── 1. Simple expression ──────────────────────────────────────────────
  print('── Simple expression ──');
  final result = await monty.run('2 + 2');
  print('  2 + 2 = ${result.value}');
  print('  Memory: ${result.usage.memoryBytesUsed} bytes');

  // ── 2. Multi-line code ────────────────────────────────────────────────
  print('\n── Multi-line code ──');
  final fib = await monty.run('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
fib(10)
''');
  print('  fib(10) = ${fib.value}');

  // ── 3. Resource limits ────────────────────────────────────────────────
  print('\n── Resource limits ──');
  final limited = await monty.run(
    '"hello " * 3',
    limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  print('  "hello " * 3 = ${limited.value}');

  // ── 4. Error handling ─────────────────────────────────────────────────
  print('\n── Error handling ──');
  try {
    await monty.run('1 / 0');
  } on MontyException catch (e) {
    print('  Caught: ${e.message}');
  }

  // ── 5. Iterative execution (external functions) ───────────────────────
  print('\n── Iterative execution ──');
  var progress = await monty.start(
    '''
data = fetch("https://example.com")
len(data)
''',
    externalFunctions: ['fetch'],
  );

  while (progress is MontyPending) {
    final pending = progress;
    print('  Python called: ${pending.functionName}(${pending.arguments})');

    // Simulate the external function returning data
    progress = await monty.resume('<html>Hello from Dart!</html>');
  }

  final complete = progress as MontyComplete;
  print('  Result: ${complete.result.value}');

  // ── 6. Error injection ────────────────────────────────────────────────
  print('\n── Error injection ──');
  var errProgress = await monty.start(
    '''
try:
    data = fetch("https://fail.example.com")
except Exception as e:
    result = f"caught: {e}"
result
''',
    externalFunctions: ['fetch'],
  );

  if (errProgress is MontyPending) {
    print('  Injecting error into Python...');
    errProgress = await monty.resumeWithError('network timeout');
  }

  final errComplete = errProgress as MontyComplete;
  print('  Result: ${errComplete.result.value}');

  await monty.dispose();
  print('\nDone.');
}
