// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
/// Async / sync matrix demo — FFI (native).
///
/// Walks through the six cells of the (Dart × Python) async/sync matrix
/// from a user's perspective. Each cell prints what it's doing so a
/// developer skimming the source can learn the matrix in five minutes.
///
/// Prerequisites:
///   cd native && cargo build --release   # one-time, from repo root
///
/// Run from the repo root:
///   dart run example/native/bin/async_matrix_demo.dart
///
/// Spec:
///   dart_monty_core/docs/deep-dives/async-matrix.md
library;

import 'package:dart_monty/dart_monty_bridge.dart';

/// A sync host fn — returns its result without ever yielding the event loop.
HostFunction syncFetch(void Function() onCall) => HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Sync fetch — adds 1 to its argument.',
    params: [HostParam(name: 'value', type: HostParamType.integer)],
  ),
  handler: (args, _) async {
    onCall();
    return (args['value']! as int) + 1;
  },
);

/// An async host fn — actually awaits a Future before returning.
HostFunction asyncFetch(void Function() onCall) => HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Async fetch — awaits Future.delayed, then adds 1.',
    params: [HostParam(name: 'value', type: HostParamType.integer)],
  ),
  handler: (args, _) async {
    await Future<void>.delayed(Duration.zero);
    onCall();
    return (args['value']! as int) + 1;
  },
);

/// A slow async host fn — sleeps `delay` before returning, so we can see
/// `asyncio.gather` flatten wall-clock time.
HostFunction slowFetch(Duration delay) => HostFunction(
  schema: const HostFunctionSchema(
    name: 'slow',
    description: 'Sleeps then returns its argument times 10.',
    params: [HostParam(name: 'n', type: HostParamType.integer)],
  ),
  handler: (args, _) async {
    await Future<void>.delayed(delay);
    return (args['n']! as int) * 10;
  },
);

/// Like [asyncFetch] but declared [DispatchMode.future] so Python can
/// directly `await` it.
HostFunction asyncFetchFuture(void Function() onCall) => HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Async fetch (future-mode) — awaits Future.delayed, adds 1.',
    params: [HostParam(name: 'value', type: HostParamType.integer)],
  ),
  handler: (args, _) async {
    await Future<void>.delayed(Duration.zero);
    onCall();
    return (args['value']! as int) + 1;
  },
  dispatch: DispatchMode.future,
);

/// Like [slowFetch] but declared [DispatchMode.future] so `asyncio.gather`
/// can run multiple calls concurrently.
HostFunction slowFetchFuture(Duration delay) => HostFunction(
  schema: const HostFunctionSchema(
    name: 'slow',
    description: 'Sleeps then returns its argument times 10 (future-mode).',
    params: [HostParam(name: 'n', type: HostParamType.integer)],
  ),
  handler: (args, _) async {
    await Future<void>.delayed(delay);
    return (args['n']! as int) * 10;
  },
  dispatch: DispatchMode.future,
);

Future<void> main() async {
  print('═══════════════════════════════════════════════════════════════');
  print(' dart_monty async/sync matrix — FFI demo');
  print('═══════════════════════════════════════════════════════════════');
  print('');
  print('Each cell exercises one (Dart handler shape) × (Python call shape)');
  print('combination. Spec: dart_monty_core/docs/deep-dives/async-matrix.md');
  print('');

  // ── Cell 1: sync Dart × bare Python ──────────────────────────────────
  // The simplest possible interaction. Python calls fetch(7), Dart
  // returns synchronously, Python sees the value. No `await` anywhere.
  print('── Cell 1: sync Dart × bare Python ────────────────────────────');
  {
    var calls = 0;
    final runtime = MontyRuntime()..register(syncFetch(() => calls++));
    final r = await runtime.execute('fetch(7)').result;
    print('  Python: fetch(7)');
    print('  → value = ${r.value.dartValue}, callback fired $calls time(s).');
    await runtime.dispose();
  }
  print('');

  // ── Cell 2: async Dart × bare Python ─────────────────────────────────
  // Same Python, but the handler awaits a Future before returning.
  // The bridge resolves the Dart-side Future for us; Python is none the
  // wiser — it sees the value, not a coroutine.
  print('── Cell 2: async Dart × bare Python ───────────────────────────');
  {
    var calls = 0;
    final runtime = MontyRuntime()..register(asyncFetch(() => calls++));
    final r = await runtime.execute('fetch(7)').result;
    print('  Python: fetch(7)   (handler awaits Future.delayed first)');
    print('  → value = ${r.value.dartValue}, callback fired $calls time(s).');
    await runtime.dispose();
  }
  print('');

  // ── Cell 3: sync Dart × Python local coroutine ───────────────────────
  // Now Python wraps the call in a coroutine. The `await doubled(3)` is
  // a Python-local await — it does NOT cross the FFI boundary as a
  // future. fetch() is still called bare from inside the coroutine.
  // No MontyResolveFutures involved.
  print('── Cell 3: sync Dart × Python local coroutine ─────────────────');
  {
    var calls = 0;
    final runtime = MontyRuntime()..register(syncFetch(() => calls++));
    final r = await runtime.execute('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').result;
    print('  Python: async def doubled(n): return fetch(n) * 2');
    print('          await doubled(3)');
    print('  → value = ${r.value.dartValue}, callback fired $calls time(s).');
    await runtime.dispose();
  }
  print('');

  // ── Cell 4: async Dart × Python local coroutine ──────────────────────
  // Same Python as cell 3. Same Python-side semantics. The handler is
  // async on the Dart side now, but from Python's point of view nothing
  // changes — fetch() returns a value, not a future.
  print('── Cell 4: async Dart × Python local coroutine ────────────────');
  {
    var calls = 0;
    final runtime = MontyRuntime()..register(asyncFetch(() => calls++));
    final r = await runtime.execute('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').result;
    print('  Python: async def doubled(n): return fetch(n) * 2');
    print('          await doubled(3)   (handler is async Dart)');
    print('  → value = ${r.value.dartValue}, callback fired $calls time(s).');
    await runtime.dispose();
  }
  print('');

  // ── Cell 5a: async Dart × Python `await ext()` ───────────────────────
  // The KEY cell. Python directly awaits the host fn:
  //
  //     result = await fetch(7)
  //
  // For this to work the fn must be declared DispatchMode.future so the
  // bridge hands Python a coroutine object rather than a plain value.
  //
  // Step 1 shows the default (DispatchMode.sync) raises TypeError —
  // Python can't await an int.
  // Step 2 uses DispatchMode.future and it just works.
  print('── Cell 5a: async Dart × Python `await ext()` ─────────────────');
  print('  Step 1 — DispatchMode.sync (the default):');
  {
    final runtime = MontyRuntime()..register(asyncFetch(() {}));
    final r = await runtime.execute('await fetch(7)').result;
    if (r.isError) {
      print('    Python raised ${r.error?.excType}: ${r.error?.message}');
      print('    (Expected — int is not awaitable.)');
    } else {
      print('    unexpectedly succeeded: ${r.value.dartValue}');
    }
    await runtime.dispose();
  }
  print('  Step 2 — DispatchMode.future:');
  {
    var calls = 0;
    final runtime = MontyRuntime()..register(asyncFetchFuture(() => calls++));
    final r = await runtime.execute('await fetch(7)').result;
    print('    Python: await fetch(7)');
    print(
      '    → value = ${r.value.dartValue}, '
      'callback fired $calls time(s).',
    );
    await runtime.dispose();
  }
  print('');

  // ── Cell 5b: asyncio.gather + DispatchMode.future ────────────────────
  // The pay-off cell. Three host calls each sleep 200ms. With
  // DispatchMode.future, asyncio.gather runs them concurrently — wall
  // clock should be ~200ms, NOT ~600ms.
  print('── Cell 5b: asyncio.gather + DispatchMode.future ───────────────');
  {
    const delay = Duration(milliseconds: 200);
    final runtime = MontyRuntime()..register(slowFetchFuture(delay));
    final sw = Stopwatch()..start();
    final r = await runtime.execute('''
import asyncio
results = await asyncio.gather(slow(1), slow(2), slow(3))
results
''').result;
    sw.stop();
    print('  Python: await asyncio.gather(slow(1), slow(2), slow(3))');
    print('          (each handler sleeps ${delay.inMilliseconds}ms)');
    print('  → value      = ${r.value.dartValue}');
    print('  → wall clock = ${sw.elapsedMilliseconds}ms');
    print(
      '    (sequential would be ~${delay.inMilliseconds * 3}ms; '
      'concurrent should be ~${delay.inMilliseconds}ms.)',
    );
    await runtime.dispose();
  }
  print('');

  print('═══════════════════════════════════════════════════════════════');
  print(' Done.');
  print('═══════════════════════════════════════════════════════════════');
}
