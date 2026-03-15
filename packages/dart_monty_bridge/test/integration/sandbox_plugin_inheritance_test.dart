@Tags(['integration'])
library;

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Wraps a single Python expression in async-def/await for futures-mode
/// child bridges. Backslash-n are literal (for embedding in spawn code=).
String _asyncChild(String expr) {
  return ['async def w():', '    return await $expr', 'await w()'].join(r'\n');
}

/// Integration tests for SandboxPlugin child inheritance with real FFI.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/sandbox_plugin_inheritance_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  MontyPlatform createPlatform() => MontyFfi(bindings: bindings);

  /// Executes [code] on a bridge and returns the final value or throws.
  Future<Object?> run(DefaultMontyBridge bridge, String code) async {
    Object? result;
    String? error;
    await for (final event in bridge.execute(code)) {
      if (event is BridgeRunFinished) {
        result = event.value;
      } else if (event is BridgeRunError) {
        error = event.message;
      }
    }
    if (error != null) throw Exception(error);
    return result;
  }

  /// Python expression: `sandbox_spawn(code="[childCode]")`.
  String spawn(String childCode) => 'sandbox_spawn(code="$childCode")';

  // Parent bridge uses useFutures: false for simpler test code.
  // Child bridges (created by SandboxPlugin) use useFutures: true by default,
  // so child code calling host functions must use async def + await.
  DefaultMontyBridge createBridge() =>
      DefaultMontyBridge(platform: createPlatform(), useFutures: false);

  // ---------------------------------------------------------------------------
  // Baseline: child sandboxs work without plugins
  // ---------------------------------------------------------------------------

  group('baseline (no plugins)', () {
    test('child sandbox computes and returns value', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      // Host functions are called synchronously from Python — the parent
      // bridge has useFutures: false.
      final result = await run(
        bridge,
        'h = ${spawn("2 + 3")}\n'
        'sandbox_await(handle=h)',
      );

      expect(result, 5);
      bridge.dispose();
    });

    test('child sandbox captures print output', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      final result = await run(
        bridge,
        'h = ${spawn("print(42)")}\n'
        'sandbox_await(handle=h)\n'
        'sandbox_get_output(handle=h)',
      );

      expect(result, contains('42'));
      bridge.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // createChildInstance inheritance
  // ---------------------------------------------------------------------------

  group('createChildInstance inheritance', () {
    test('parent can call inherited plugin function', () async {
      final bridge = createBridge();
      final greeter = _GreeterPlugin();
      final registry = PluginRegistry()
        ..register(greeter)
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            parentPlugins: [greeter],
          ),
        );
      await registry.attachTo(bridge);

      final result = await run(bridge, 'greeter_hello(name="parent")');

      expect(result, 'Hello, parent!');
      bridge.dispose();
    });

    test('child inherits plugin via createChildInstance', () async {
      final bridge = createBridge();
      final greeter = _GreeterPlugin();
      final registry = PluginRegistry()
        ..register(greeter)
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            parentPlugins: [greeter],
          ),
        );
      await registry.attachTo(bridge);

      // Child bridge uses futures by default — child code must use
      // async def + await for host function calls.
      final cc = _asyncChild(r'greeter_hello(name=\"child\")');
      final result = await run(
        bridge,
        'h = ${spawn(cc)}\n'
        'sandbox_await(handle=h)',
      );

      expect(result, 'Hello, child!');
      bridge.dispose();
    });

    test('child without inheritable plugins errors on call', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      // Child calls greeter_hello — not available (no inheritance).
      final cc = _asyncChild(r'greeter_hello(name=\"test\")');
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
      bridge.dispose();
    });

    test('multiple children get independent plugin instances', () async {
      final bridge = createBridge();
      final counter = _CounterPlugin();
      final registry = PluginRegistry()
        ..register(counter)
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            parentPlugins: [counter],
          ),
        );
      await registry.attachTo(bridge);

      // Each child increments its own counter independently.
      final cc = [
        'async def w():',
        '    await counter_increment()',
        '    return await counter_get()',
        'await w()',
      ].join(r'\n');
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
      expect(results[0], 1);
      expect(results[1], 1);

      // Parent counter untouched.
      expect(counter.count, 0);
      bridge.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // childPluginRegistryFactory precedence
  // ---------------------------------------------------------------------------

  group('childPluginRegistryFactory precedence', () {
    test('factory takes precedence over parentPlugins', () async {
      final bridge = createBridge();
      final greeter = _GreeterPlugin();
      final registry = PluginRegistry()
        ..register(greeter)
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            parentPlugins: [greeter],
            childPluginRegistryFactory: (_) async {
              // Empty registry — no parent inheritance.
              return PluginRegistry();
            },
          ),
        );
      await registry.attachTo(bridge);

      // Child should NOT have greeter_hello (factory overrides).
      final cc = _asyncChild(r'greeter_hello(name=\"test\")');
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
      bridge.dispose();
    });
  });
  // ---------------------------------------------------------------------------
  // ChildSpawnContext threading
  // ---------------------------------------------------------------------------

  group('ChildSpawnContext threading', () {
    test(
      'child receives context with working directory via real FFI',
      () async {
        ChildSpawnContext? capturedContext;
        final contextPlugin = _ContextCapturingPlugin(
          onContext: (ctx) => capturedContext = ctx,
        );
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(contextPlugin)
          ..register(
            SandboxPlugin(
              platformFactory: () async => createPlatform(),
              sandboxBaseDir: '/tmp/sandbox_test',
              parentPlugins: [contextPlugin],
            ),
          );
        await registry.attachTo(bridge);

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
          contains('.sandboxes/child_0'),
        );
        bridge.dispose();
      },
    );

    test(
      'context has null workingDirectory when sandboxBaseDir unset',
      () async {
        ChildSpawnContext? capturedContext;
        final contextPlugin = _ContextCapturingPlugin(
          onContext: (ctx) => capturedContext = ctx,
        );
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(contextPlugin)
          ..register(
            SandboxPlugin(
              platformFactory: () async => createPlatform(),
              parentPlugins: [contextPlugin],
            ),
          );
        await registry.attachTo(bridge);

        final result = await run(
          bridge,
          'h = ${spawn("1 + 1")}\n'
          'sandbox_await(handle=h)',
        );

        expect(result, 2);
        expect(capturedContext, isNotNull);
        expect(capturedContext!.childId, 0);
        expect(capturedContext!.workingDirectory, isNull);
        bridge.dispose();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test plugins
// ---------------------------------------------------------------------------

/// Simple plugin that provides `greeter_hello(name)`.
class _GreeterPlugin extends MontyPlugin {
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
      handler: (args) async => 'Hello, ${args['name']}!',
    ),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) =>
      _GreeterPlugin();
}

/// Plugin that provides a counter. Each instance has its own count.
class _CounterPlugin extends MontyPlugin {
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
      handler: (args) async => ++count,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'counter_get',
        description: 'Get the current counter value.',
      ),
      handler: (args) async => count,
    ),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) =>
      _CounterPlugin();
}

/// Plugin that captures the [ChildSpawnContext] for test assertions.
class _ContextCapturingPlugin extends MontyPlugin {
  _ContextCapturingPlugin({required this.onContext});

  final void Function(ChildSpawnContext) onContext;

  @override
  String get namespace => 'ctx_capture';

  @override
  String? get systemPromptContext => null;

  @override
  List<HostFunction> get functions => [];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    if (context != null) onContext(context);
    return null;
  }
}
