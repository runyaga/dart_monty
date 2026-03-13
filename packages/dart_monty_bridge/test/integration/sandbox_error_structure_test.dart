@Tags(['integration'])
library;

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests for child sandbox error structure preservation.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/sandbox_error_structure_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  MontyPlatform createPlatform() => MontyFfi(bindings: bindings);

  DefaultMontyBridge createBridge() =>
      DefaultMontyBridge(platform: createPlatform(), useFutures: false);

  /// Spawns a child via plugin handler and awaits it, expecting a
  /// [ChildSandboxException]. Returns the caught exception.
  Future<ChildSandboxException> spawnAndExpectFailure(
    SandboxPlugin plugin,
    String code,
  ) async {
    final spawnHandler = plugin.functions
        .firstWhere((f) => f.schema.name == 'sandbox_spawn')
        .handler;
    final awaitHandler = plugin.functions
        .firstWhere((f) => f.schema.name == 'sandbox_await')
        .handler;

    final handle = (await spawnHandler({'code': code}))! as int;

    try {
      await awaitHandler({'handle': handle});
      fail('Expected ChildSandboxException');
    } on ChildSandboxException catch (e) {
      return e;
    }
  }

  group('child error structure preservation', () {
    test(
      'ChildSandboxException preserves excType from child NameError',
      () async {
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.plugins.whereType<SandboxPlugin>().first;
        final caught = await spawnAndExpectFailure(
          plugin,
          'undefined_variable_xyz',
        );

        expect(caught.message, contains('NameError'));
        expect(caught.exception, isNotNull);
        expect(caught.exception!.excType, 'NameError');

        bridge.dispose();
      },
    );

    test(
      'ChildSandboxException preserves info from child SyntaxError',
      () async {
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.plugins.whereType<SandboxPlugin>().first;
        final caught = await spawnAndExpectFailure(plugin, 'def (');

        expect(caught.exception, isNotNull);
        expect(caught.exception!.message, isNotEmpty);

        bridge.dispose();
      },
    );

    test(
      'cancelled child throws ChildSandboxException without exception field',
      () async {
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.plugins.whereType<SandboxPlugin>().first;
        final spawnHandler = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_spawn')
            .handler;
        final cancelHandler = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_cancel')
            .handler;
        final awaitHandler = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_await')
            .handler;

        // Spawn a long-running child.
        final handle =
            (await spawnHandler({
                  'code': 'x = 0\nwhile x < 999999999:\n    x = x + 1\nx',
                }))!
                as int;

        await cancelHandler({'handle': handle});

        try {
          await awaitHandler({'handle': handle});
          fail('Expected ChildSandboxException');
        } on ChildSandboxException catch (e) {
          expect(e.message, 'cancelled');
          expect(e.exception, isNull);
        }

        bridge.dispose();
      },
    );
  });
}
