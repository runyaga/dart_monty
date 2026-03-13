@Tags(['integration'])
library;

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests for sandbox_gather output attribution with real FFI.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/sandbox_gather_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  MontyPlatform createPlatform() => MontyFfi(bindings: bindings);

  DefaultMontyBridge createBridge() =>
      DefaultMontyBridge(platform: createPlatform(), useFutures: false);

  group('sandbox_gather with real FFI', () {
    test(
      'attributes print output and return value to correct worker',
      () async {
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.plugins.whereType<SandboxPlugin>().first;
        final spawn = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_spawn')
            .handler;
        final gather = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_gather')
            .handler;

        // Spawn 3 workers with distinct print output and return values.
        final h0 = (await spawn({'code': 'print("worker-A")\n42'}))! as int;
        final h1 = (await spawn({'code': 'print("worker-B")\n99'}))! as int;
        final h2 = (await spawn({'code': 'print("worker-C")\n7'}))! as int;

        final results =
            (await gather({
                  'handles': [h0, h1, h2],
                }))!
                as List<Object?>;

        expect(results, hasLength(3));

        final r0 = results[0]! as Map<String, Object?>;
        final r1 = results[1]! as Map<String, Object?>;
        final r2 = results[2]! as Map<String, Object?>;

        // Each result is attributed to the correct handle.
        expect(r0['handle'], h0);
        expect(r1['handle'], h1);
        expect(r2['handle'], h2);

        // Return values match.
        expect(r0['value'], 42);
        expect(r1['value'], 99);
        expect(r2['value'], 7);

        // Print output is attributed correctly.
        expect(r0['output'], contains('worker-A'));
        expect(r1['output'], contains('worker-B'));
        expect(r2['output'], contains('worker-C'));

        bridge.dispose();
      },
    );

    test('gather preserves requested handle order', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      final plugin = registry.plugins.whereType<SandboxPlugin>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final gather = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_gather')
          .handler;

      final h0 = (await spawn({'code': '10'}))! as int;
      final h1 = (await spawn({'code': '20'}))! as int;

      // Request in reverse order.
      final results =
          (await gather({
                'handles': [h1, h0],
              }))!
              as List<Object?>;

      expect((results[0]! as Map)['handle'], h1);
      expect((results[0]! as Map)['value'], 20);
      expect((results[1]! as Map)['handle'], h0);
      expect((results[1]! as Map)['value'], 10);

      bridge.dispose();
    });

    test('gather with silent worker returns null output', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      final plugin = registry.plugins.whereType<SandboxPlugin>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final gather = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_gather')
          .handler;

      // One worker prints, the other does not.
      final hLoud = (await spawn({'code': 'print("hello")\n1'}))! as int;
      final hSilent = (await spawn({'code': '2'}))! as int;

      final results =
          (await gather({
                'handles': [hLoud, hSilent],
              }))!
              as List<Object?>;

      final rLoud = results[0]! as Map<String, Object?>;
      final rSilent = results[1]! as Map<String, Object?>;

      expect(rLoud['output'], contains('hello'));
      expect(rSilent['output'], isNull);

      bridge.dispose();
    });

    test('gather propagates child failure as ChildSandboxException', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(platformFactory: () async => createPlatform()),
        );
      await registry.attachTo(bridge);

      final plugin = registry.plugins.whereType<SandboxPlugin>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final gather = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_gather')
          .handler;

      final hGood = (await spawn({'code': '1'}))! as int;
      final hBad = (await spawn({'code': 'undefined_variable_xyz'}))! as int;

      expect(
        () => gather({
          'handles': [hGood, hBad],
        }),
        throwsA(
          isA<ChildSandboxException>().having(
            (e) => e.message,
            'message',
            contains('NameError'),
          ),
        ),
      );

      bridge.dispose();
    });

    test(
      'gather results are machine-parseable for downstream tooling',
      () async {
        final bridge = createBridge();
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => createPlatform()),
          );
        await registry.attachTo(bridge);

        final plugin = registry.plugins.whereType<SandboxPlugin>().first;
        final spawn = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_spawn')
            .handler;
        final gather = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_gather')
            .handler;

        final h0 =
            (await spawn({'code': 'print("line1")\nprint("line2")\n100'}))!
                as int;
        final h1 = (await spawn({'code': 'print("only")\n200'}))! as int;

        final results =
            (await gather({
                  'handles': [h0, h1],
                }))!
                as List<Object?>;

        // Verify every result has exactly the expected keys.
        for (final raw in results) {
          final r = raw! as Map<String, Object?>;
          expect(r.keys, containsAll(['handle', 'value', 'output']));
          expect(r['handle'], isA<int>());
        }

        // Verify multiline output is captured intact.
        final r0 = results[0]! as Map<String, Object?>;
        final output = r0['output']! as String;
        expect(output, contains('line1'));
        expect(output, contains('line2'));

        bridge.dispose();
      },
    );
  });
}
