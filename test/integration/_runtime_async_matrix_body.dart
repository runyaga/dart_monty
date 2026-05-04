// Shared test body for the Layer 4 (`MontyRuntime.execute`) async/sync
// matrix.
//
// Layer 4 takes a different code path than Layer 2/3 (which go through
// dart_monty_core's `MontyRepl.feedRun` → `_driveLoop`). MontyRuntime
// builds a `PlatformBridge` that is always futures-capable; per-fn
// `DispatchMode` selects sync vs future dispatch for each call.
//
// `ffi_runtime_async_matrix_test.dart` calls [runRuntimeAsyncMatrixTests]
// (FFI only — dart_monty has no WASM-tagged integration suite).

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void runRuntimeAsyncMatrixTests() {
  group('MontyRuntime.execute async/sync matrix', () {
    HostFunction fetchSync(int Function() onCall) => HostFunction(
      schema: const HostFunctionSchema(
        name: 'fetch',
        description: 'sync fetch',
        params: [HostParam(name: 'value', type: HostParamType.integer)],
      ),
      handler: (args, _) async {
        onCall();

        return (args['value']! as int) + 1;
      },
    );

    HostFunction fetchAsync(int Function() onCall) => HostFunction(
      schema: const HostFunctionSchema(
        name: 'fetch',
        description: 'async fetch',
        params: [HostParam(name: 'value', type: HostParamType.integer)],
      ),
      handler: (args, _) async {
        await Future<void>.delayed(Duration.zero);
        onCall();

        return (args['value']! as int) + 1;
      },
    );

    HostFunction fetchAsyncFuture(int Function() onCall) => HostFunction(
      schema: const HostFunctionSchema(
        name: 'fetch',
        description: 'async fetch (future-mode)',
        params: [HostParam(name: 'value', type: HostParamType.integer)],
      ),
      handler: (args, _) async {
        await Future<void>.delayed(Duration.zero);
        onCall();

        return (args['value']! as int) + 1;
      },
      dispatch: DispatchMode.future,
    );

    // matrix-cell: (sync Dart) × (sync Python)
    test('cell 1: sync handler + bare Python call', () async {
      var calls = 0;
      final runtime = MontyRuntime()..register(fetchSync(() => calls++));
      addTearDown(runtime.dispose);

      final r = await runtime.execute('fetch(7)').result;

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (sync Python)
    test('cell 2: async handler + bare Python call', () async {
      var calls = 0;
      final runtime = MontyRuntime()..register(fetchAsync(() => calls++));
      addTearDown(runtime.dispose);

      final r = await runtime.execute('fetch(7)').result;

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (sync Dart) × (Python local async coroutine, no Dart await)
    test('cell 3: sync handler + Python local coroutine', () async {
      var calls = 0;
      final runtime = MontyRuntime()..register(fetchSync(() => calls++));
      addTearDown(runtime.dispose);

      final r = await runtime.execute('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').result;

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (Python local coroutine)
    test('cell 4: async handler + Python local coroutine', () async {
      var calls = 0;
      final runtime = MontyRuntime()..register(fetchAsync(() => calls++));
      addTearDown(runtime.dispose);

      final r = await runtime.execute('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').result;

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (Python `await ext()`) — the key cell.
    // Handler declares DispatchMode.future so the bridge uses resumeAsFuture.
    test(
      'cell 5a: DispatchMode.future wires Python `await fetch(x)`',
      () async {
        var calls = 0;
        final runtime = MontyRuntime()
          ..register(fetchAsyncFuture(() => calls++));
        addTearDown(runtime.dispose);

        final r = await runtime.execute('await fetch(7)').result;

        expect(r.error, isNull);
        expect(r.value.dartValue, 8);
        expect(calls, 1);
      },
    );

    test(
      'cell 5b: DispatchMode.future + asyncio.gather over externals',
      () async {
        final fired = <int>[];
        final runtime = MontyRuntime()
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'fetch',
                description: 'parallel fetch',
                params: [HostParam(name: 'n', type: HostParamType.integer)],
              ),
              handler: (args, _) async {
                final n = args['n']! as int;
                fired.add(n);
                await Future<void>.delayed(Duration.zero);

                return n * 10;
              },
              dispatch: DispatchMode.future,
            ),
          );
        addTearDown(runtime.dispose);

        final r = await runtime.execute('''
import asyncio
results = await asyncio.gather(fetch(1), fetch(2), fetch(3))
results
''').result;

        expect(r.error, isNull);
        expect(r.value.dartValue, [10, 20, 30]);
        // Concurrent dispatch — all three callbacks fire (in some order)
        // before gather yields.
        expect(fired.toSet(), {1, 2, 3});
        expect(fired, hasLength(3));
      },
    );

    // Back-compat: handler with default DispatchMode.sync leaves Python
    // `await ext()` raising TypeError — same observable failure as before,
    // now because the handler declared sync rather than because a runtime
    // flag was unset.
    test(
      'DispatchMode.sync (default): Python `await ext()` raises TypeError',
      () async {
        final runtime = MontyRuntime()..register(fetchAsync(() => 0));
        addTearDown(runtime.dispose);

        final r = await runtime.execute('await fetch(7)').result;

        expect(r.error, isNotNull);
        expect(r.error?.excType, equals('TypeError'));
      },
    );

    // DispatchMode.future + inputs interplay — confirm per-fn dispatch
    // composes with the existing inputs: parameter.
    test(
      'DispatchMode.future + inputs: inputs visible inside awaited external',
      () async {
        final runtime = MontyRuntime()
          ..register(
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'greet',
                description: 'greet by name',
                params: [HostParam(name: 'name', type: HostParamType.string)],
              ),
              handler: (args, _) async {
                await Future<void>.delayed(Duration.zero);

                return 'hello, ${args['name']}';
              },
              dispatch: DispatchMode.future,
            ),
          );
        addTearDown(runtime.dispose);

        final r = await runtime
            .execute(
              'await greet(seed)',
              inputs: {'seed': 'alice'},
            )
            .result;

        expect(r.error, isNull);
        expect(r.value.dartValue, 'hello, alice');
      },
    );

    // asyncio.gather demonstrates wall-clock parallelism — sleep-heavy
    // handlers run concurrently rather than sequentially when declared
    // DispatchMode.future.
    test('DispatchMode.future: gather of slow handlers takes ~one delay, '
        'not sum-of-delays', () async {
      const delayMs = 200;
      final runtime = MontyRuntime()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'slow',
              description: 'sleeps then returns its argument',
              params: [HostParam(name: 'n', type: HostParamType.integer)],
            ),
            handler: (args, _) async {
              await Future<void>.delayed(
                const Duration(milliseconds: delayMs),
              );

              return args['n'];
            },
            dispatch: DispatchMode.future,
          ),
        );
      addTearDown(runtime.dispose);

      final sw = Stopwatch()..start();
      final r = await runtime.execute('''
import asyncio
await asyncio.gather(slow(1), slow(2), slow(3))
''').result;
      sw.stop();

      expect(r.error, isNull);
      expect(r.value.dartValue, [1, 2, 3]);
      // Sequential would be ~3*delayMs (600ms). Concurrent is ~delayMs
      // plus dispatch overhead. Use 2x delay as the upper bound — well
      // below the sequential lower bound and well above any noise.
      expect(
        sw.elapsedMilliseconds,
        lessThan(delayMs * 2),
        reason:
            'gather should run handlers concurrently under '
            'DispatchMode.future; took ${sw.elapsedMilliseconds}ms',
      );
    });
  });
}
