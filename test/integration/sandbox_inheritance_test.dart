@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';

/// Integration tests for SandboxExtension child inheritance with real FFI.
///
/// Run with:
/// ```bash
/// dart test --tags=integration --run-skipped \
///   test/integration/sandbox_inheritance_test.dart
/// ```
void main() {
  late Monty pool;

  setUpAll(
    () async => pool = await Monty.start(
      workerLocation: acceptanceWorkerLocation,
      checkoutTimeout: const Duration(seconds: 5),
    ),
  );
  tearDownAll(() => pool.close());

  /// Executes [code] on a bridge and returns the final value or throws.
  Future<Object?> run(MontyRuntime runtime, String code) async =>
      (await runtime.execute(code).result).dartValue;

  /// Python expression: `sandbox_spawn(code="[childCode]")`.
  String spawn(String childCode) => 'sandbox_spawn(code="$childCode")';

  Future<MontyRuntime> createBridge(List<MontyExtension> extensions) async {
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: extensions,
    );
    addTearDown(runtime.dispose);
    await runtime.invoke('sandbox_await_all', {'handles': const MontyList([])});

    return runtime;
  }

  // ---------------------------------------------------------------------------
  // Baseline: child sandboxs work without plugins
  // ---------------------------------------------------------------------------

  group('baseline (no plugins)', () {
    test('child sandbox computes and returns value', () async {
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      // Host functions are called synchronously (DispatchMode.sync default).
      final result = await run(
        bridge,
        'h = ${spawn("2 + 3")}\n'
        'sandbox_await(handle=h)',
      );

      expect(result, 5);
      await bridge.dispose();
    });

    test('child sandbox captures print output', () async {
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      final result = await run(
        bridge,
        'h = ${spawn("print(42)")}\n'
        'sandbox_await(handle=h)\n'
        'sandbox_get_output(handle=h)',
      );

      expect(result, contains('42'));
      await bridge.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // createChildInstance inheritance
  // ---------------------------------------------------------------------------

  group('createChildInstance inheritance', () {
    test('parent can call inherited plugin function', () async {
      final greeter = _GreeterExtension();
      final registry = ExtensionCoordinator()
        ..register(greeter)
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      final result = await run(bridge, 'greeter_hello(name="parent")');

      expect(result, 'Hello, parent!');
      await bridge.dispose();
    });

    test(
      'child inherits plugin via createChildInstance',

      () async {
        final greeter = _GreeterExtension();
        final registry = ExtensionCoordinator()
          ..register(greeter)
          ..register(
            SandboxExtension(),
          );
        final bridge = await createBridge(registry.extensions);

        // Child bridge dispatch is sync by default — direct calls.
        const cc = r'greeter_hello(name=\"child\")';
        final result = await run(
          bridge,
          'h = ${spawn(cc)}\n'
          'sandbox_await(handle=h)',
        );

        expect(result, 'Hello, child!');
        await bridge.dispose();
      },
    );

    test(
      'child without inheritable plugins errors on call',

      () async {
        final registry = ExtensionCoordinator()
          ..register(
            SandboxExtension(),
          );
        final bridge = await createBridge(registry.extensions);

        // Child calls greeter_hello — not available (no inheritance).
        const cc = r'greeter_hello(name=\"test\")';
        final result = await run(
          bridge,
          'h = ${spawn(cc)}\n'
          'try:\n'
          '    sandbox_await(handle=h)\n'
          '    result = "should_not_reach"\n'
          'except:\n'
          '    result = "error_caught"\n'
          'result',
        );

        expect(result, 'error_caught');
        await bridge.dispose();
      },
    );

    test(
      'multiple children get independent plugin instances',

      () async {
        final counter = _CounterExtension();
        final registry = ExtensionCoordinator()
          ..register(counter)
          ..register(
            SandboxExtension(),
          );
        final bridge = await createBridge(registry.extensions);

        // Each child increments its own counter independently.
        // Dispatch is sync (DispatchMode.sync default) — direct calls, no async/await needed.
        final cc = ['counter_increment()', 'counter_get()'].join(r'\n');
        final result = await run(
          bridge,
          'h1 = ${spawn(cc)}\n'
          'h2 = ${spawn(cc)}\n'
          'r1 = sandbox_await(handle=h1)\n'
          'r2 = sandbox_await(handle=h2)\n'
          '[r1, r2]',
        );

        final results = result! as List;
        // Each child has its own counter starting at 0.
        expect(results.first, 1);
        expect(results[1], 1);

        // Parent counter untouched.
        expect(counter.count, 0);
        await bridge.dispose();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // ChildSpawnContext threading
  // ---------------------------------------------------------------------------

  group('ChildSpawnContext threading', () {
    test(
      'child receives context with working directory via real FFI',
      () async {
        ChildSpawnContext? capturedContext;
        final contextPlugin = _ContextCapturingExtension(
          onContext: (ctx) => capturedContext = ctx,
        );
        final registry = ExtensionCoordinator()
          ..register(contextPlugin)
          ..register(
            SandboxExtension(
              sandboxBaseDir: '/tmp/sandbox_test',
            ),
          );
        final bridge = await createBridge(registry.extensions);

        if (!hasWorkerProcesses) {
          // A browser has no native workspace backing: a base directory is
          // refused instead of silently falling back to memory.
          await expectLater(
            run(bridge, 'h = ${spawn("2 + 2")}\nsandbox_await(handle=h)'),
            throwsA(
              predicate(
                (e) => e.toString().contains('unavailable on web'),
              ),
            ),
          );
          await bridge.dispose();

          return;
        }

        final result = await run(
          bridge,
          'h = ${spawn("2 + 2")}\n'
          'sandbox_await(handle=h)',
        );

        expect(result, 4);
        expect(capturedContext, isNotNull);
        expect(capturedContext!.childId, 0);
        expect(
          capturedContext!.workingDirectory,
          '/work',
        );
        await bridge.dispose();
      },
    );

    test(
      'context has null workingDirectory when sandboxBaseDir unset',
      () async {
        ChildSpawnContext? capturedContext;
        final contextPlugin = _ContextCapturingExtension(
          onContext: (ctx) => capturedContext = ctx,
        );
        final registry = ExtensionCoordinator()
          ..register(contextPlugin)
          ..register(
            SandboxExtension(),
          );
        final bridge = await createBridge(registry.extensions);

        final result = await run(
          bridge,
          'h = ${spawn("1 + 1")}\n'
          'sandbox_await(handle=h)',
        );

        expect(result, 2);
        expect(capturedContext, isNotNull);
        expect(capturedContext!.childId, 0);
        expect(capturedContext!.workingDirectory, '/work');
        await bridge.dispose();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test plugins
// ---------------------------------------------------------------------------

/// Simple plugin that provides `greeter_hello(name)`.
class _GreeterExtension extends MontyExtension {
  @override
  String get namespace => 'greeter';

  @override
  String? get systemPromptContext => 'Greeting plugin.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'greeter_hello',
        description: 'Returns a greeting.',
        params: [
          HostParam(
            name: 'name',
            type: HostParamType.string,
            description: 'Name to greet.',
          ),
        ],
      ),
      handler: (args, _) async =>
          MontyString('Hello, ${(args['name']! as MontyString).value}!'),
    ),
  ];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      _GreeterExtension();
}

/// Plugin that provides a counter. Each instance has its own count.
class _CounterExtension extends MontyExtension {
  int count = 0;

  @override
  String get namespace => 'counter';

  @override
  String? get systemPromptContext => 'Counter plugin.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'counter_increment',
        description: 'Increment the counter.',
      ),
      handler: (args, _) async => MontyValue.fromDart(++count),
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'counter_get',
        description: 'Get the current counter value.',
      ),
      handler: (args, _) async => MontyValue.fromDart(count),
    ),
  ];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      _CounterExtension();
}

/// Plugin that captures the [ChildSpawnContext] for test assertions.
class _ContextCapturingExtension extends MontyExtension {
  _ContextCapturingExtension({required this.onContext});

  final void Function(ChildSpawnContext) onContext;

  @override
  String get namespace => 'ctx_capture';

  @override
  String? get systemPromptContext => null;

  @override
  List<HostFunction> get functions => [];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) {
    onContext(context);

    return _ContextCapturingExtension(onContext: onContext);
  }
}
