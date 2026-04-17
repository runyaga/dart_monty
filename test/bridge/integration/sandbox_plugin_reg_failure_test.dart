@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

/// Integration tests for plugin registration failure logging with real FFI.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/sandbox_plugin_reg_failure_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;
  late MemorySink sink;
  late LogLevel previousLevel;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  setUp(() {
    sink = MemorySink();
    previousLevel = LogManager.instance.minimumLevel;
    LogManager.instance
      ..addSink(sink)
      ..minimumLevel = LogLevel.trace;
  });

  tearDown(() {
    LogManager.instance
      ..removeSink(sink)
      ..minimumLevel = previousLevel;
  });

  MontyPlatform createPlatform() => MontyFfi(bindings: bindings);

  MontyBridge createBridge() => MontyBridge(
    platform: createPlatform(),
    useFutures: false,
    logger: StructLogBridgeLogger.root(LogManager.instance),
  );

  group('plugin registration failure with real FFI', () {
    test('factory failure logs phase=factory and cleans up', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            childPluginRegistryFactory: (_) async {
              throw StateError('factory boom');
            },
          ),
        );
      await registry.attachTo(bridge);

      final plugin = registry.plugins.whereType<SandboxPlugin>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;

      await expectLater(spawn({'code': '42'}), throwsStateError);

      final errorRecord = sink.records.firstWhere(
        (r) => r.message == 'Child plugin factory failed',
      );
      expect(errorRecord.level, LogLevel.error);
      expect(errorRecord.attributes['phase'], 'factory');

      bridge.dispose();
    });

    test('attachTo failure logs phase=attachTo with pluginCount', () async {
      final bridge = createBridge();
      final registry = PluginRegistry()
        ..register(
          SandboxPlugin(
            platformFactory: () async => createPlatform(),
            childPluginRegistryFactory: (_) async {
              final childRegistry = PluginRegistry()
                ..register(_IntegrationBoomPlugin());
              return childRegistry;
            },
          ),
        );
      await registry.attachTo(bridge);

      final plugin = registry.plugins.whereType<SandboxPlugin>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;

      await expectLater(spawn({'code': '42'}), throwsStateError);

      final errorRecord = sink.records.firstWhere(
        (r) => r.message == 'Child plugin attachment failed',
      );
      expect(errorRecord.level, LogLevel.error);
      expect(errorRecord.attributes['phase'], 'attachTo');
      expect(errorRecord.attributes['pluginCount'], 1);

      bridge.dispose();
    });
  });
}

/// Plugin whose [onRegister] throws for integration testing.
class _IntegrationBoomPlugin extends MontyPlugin {
  @override
  String get namespace => 'boom';

  @override
  final String? systemPromptContext = null;

  @override
  List<HostFunction> get functions => [];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    throw StateError('integration attachTo boom');
  }
}
