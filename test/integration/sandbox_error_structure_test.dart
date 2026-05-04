@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

final _testCtx = HostContext(emit: (_) {}, executionId: 'test');

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

  MontyBridge createBridge() => MontyBridge(platform: createPlatform());

  /// Spawns a child via plugin handler and awaits it, expecting a
  /// [ChildSandboxException]. Returns the caught exception.
  Future<ChildSandboxException> spawnAndExpectFailure(
    SandboxExtension plugin,
    String code,
  ) async {
    final spawnHandler = plugin.functions
        .firstWhere((f) => f.schema.name == 'sandbox_spawn')
        .handler;
    final awaitHandler = plugin.functions
        .firstWhere((f) => f.schema.name == 'sandbox_await')
        .handler;

    final handle = (await spawnHandler!({'code': code}, _testCtx))! as int;

    try {
      await awaitHandler!({'handle': handle}, _testCtx);
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
        final registry = ExtensionCoordinator()
          ..register(
            SandboxExtension(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.extensions.whereType<SandboxExtension>().first;
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
        final registry = ExtensionCoordinator()
          ..register(
            SandboxExtension(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.extensions.whereType<SandboxExtension>().first;
        final caught = await spawnAndExpectFailure(plugin, 'def (');

        expect(caught.exception, isNotNull);
        expect(caught.exception!.message, isNotEmpty);

        bridge.dispose();
      },
    );
  });
}
