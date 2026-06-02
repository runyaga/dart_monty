// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
//
// dart_monty — featured example
//
// Higher-level abstractions on top of dart_monty_core:
//
//  1. One-shot     — Monty.exec
//  2. Inputs       — chain programs: output of one run feeds the next
//  3. HostFunction — typed schema-backed callbacks; DispatchMode.future
//                    lets Python await and asyncio.gather runs concurrently
//  4. VFS          — sandboxed in-memory filesystem via Python pathlib
//  5. Persistence  — variables and functions survive across execute() calls
//
// Run: dart run example/example.dart

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  // ── 1. One-shot ───────────────────────────────────────────────────────────
  final r = await Monty.exec('2 ** 10');
  print('2**10 = ${r.value.dartValue}'); // 1024

  // ── 2. Inputs — chaining programs ────────────────────────────────────────
  // Feed the result of one Monty run into the next as a named Python variable.
  final squares = await Monty('[x**2 for x in range(10)]').run();

  final total = await Monty(
    'sum(squares)',
  ).run(inputs: {'squares': squares.value.dartValue});
  print('sum of squares 0–9² = ${total.value.dartValue}'); // 285

  // ── 3. HostFunction + DispatchMode.future ────────────────────────────────
  // Schema-backed Dart callbacks on a persistent runtime. DispatchMode.future
  // lets Python `await` the handler; asyncio.gather runs calls concurrently.
  final runtime = MontyRuntime()
    ..register(
      HostFunction(
        dispatch: DispatchMode.future,
        schema: const HostFunctionSchema(
          name: 'fetch',
          description: 'Simulates an async fetch — returns n × 10.',
          params: [HostParam(name: 'n', type: HostParamType.integer)],
        ),
        handler: (args, _) async => (args['n']! as int) * 10,
      ),
    );

  final gathered = await runtime.execute('''
import asyncio
a, b = await asyncio.gather(fetch(n=1), fetch(n=2))
a + b
''').result;
  print('gather result = ${gathered.value.dartValue}'); // 30

  // ── 4. VFS — sandboxed in-memory filesystem ───────────────────────────────
  // Python pathlib.Path reads and writes an isolated MemoryFileSystem.
  // The host filesystem is never accessed; VFS state persists across calls.
  final vfs = MontyRuntime(osHandlers: {'Path.': memoryFsHandler()});

  await vfs.execute('''
from pathlib import Path
Path('/tmp/msg.txt').write_text('Hello from Python!')
''').result;

  final msg = await vfs.execute('''
from pathlib import Path
Path('/tmp/msg.txt').read_text()
''').result;
  print('VFS file: ${msg.value.dartValue}'); // Hello from Python!

  // ── 5. Persistent state across execute() calls ────────────────────────────
  // Variables and functions defined in one execute() survive into subsequent
  // calls — the registered `fetch` from section 3 is still available.
  await runtime
      .execute('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)')
      .result;
  await runtime.execute('result = fib(10)').result;
  final fib = await runtime.execute('result').result;
  print('fib(10) = ${fib.value.dartValue}'); // 55

  await runtime.dispose();
  await vfs.dispose();
}
