// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
//
// dart_monty — featured example
//
// Higher-level abstractions on top of dart_monty_core:
//
//  1. One-shot     — a pool session runs one snippet
//  2. Inputs       — chain programs: output of one run feeds the next
//  3. HostFunction — typed schema-backed callbacks; DispatchMode.future
//                    lets Python await and asyncio.gather runs concurrently
//  4. VFS          — sandboxed in-memory filesystem via Python pathlib
//  5. Persistence  — variables and functions survive across execute() calls
//
// The worker executable is found by core's discovery, or taken from
// DART_MONTY_WORKER when set.
//
// Run: dart run example/example.dart

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  final worker = Platform.environment['DART_MONTY_WORKER'];
  final pool = await Monty.start(
    maxProcesses: 2,
    workerLocation: worker == null || worker.isEmpty ? null : worker,
  );

  try {
    // ── 1. One-shot ─────────────────────────────────────────────────────────
    final r = await pool.withSession((s) => s.feedRun('2 ** 10'));
    print('2**10 = ${r.dartValue}'); // 1024

    // ── 2. Inputs — chaining programs ──────────────────────────────────────
    // Feed the result of one run into the next as a named Python variable.
    final total = await pool.withSession((s) async {
      final squares = await s.feedRun('[x**2 for x in range(10)]');

      return s.feedRun('sum(squares)', inputs: {'squares': squares});
    });
    print('sum of squares 0–9² = ${total.dartValue}'); // 285

    // ── 3. HostFunction + DispatchMode.future ──────────────────────────────
    // Schema-backed Dart callbacks on a persistent runtime. DispatchMode.future
    // lets Python `await` the handler; asyncio.gather runs calls concurrently.
    final runtime = await MontyRuntime.start(pool: pool);
    runtime.register(
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
    print('gather result = ${gathered.dartValue}'); // 30

    // ── 4. VFS — sandboxed in-memory filesystem ─────────────────────────────
    // Python pathlib.Path reads and writes an isolated MemoryFileSystem.
    // The host filesystem is never accessed; VFS state persists across calls.
    final vfs = await MontyRuntime.start(
      pool: pool,
      osHandlers: {'Path.': memoryFsHandler()},
    );

    await vfs.execute('''
from pathlib import Path
Path('/tmp/msg.txt').write_text('Hello from Python!')
''').result;

    final msg = await vfs.execute('''
from pathlib import Path
Path('/tmp/msg.txt').read_text()
''').result;
    print('VFS file: ${msg.dartValue}'); // Hello from Python!
    await vfs.dispose();

    // ── 5. Persistent state across execute() calls ──────────────────────────
    // Variables and functions defined in one execute() survive into later
    // calls — the registered `fetch` from section 3 is still available.
    await runtime
        .execute('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)')
        .result;
    await runtime.execute('result = fib(10)').result;
    final fib = await runtime.execute('result').result;
    print('fib(10) = ${fib.dartValue}'); // 55

    await runtime.dispose();
  } finally {
    await pool.close();
  }
}
