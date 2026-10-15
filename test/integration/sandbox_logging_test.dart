@TestOn('vm')
@Tags(['integration', 'd1-pending'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

import '_worker.dart';

final _testCtx = HostContext(emit: (_) {}, executionId: 'test');

/// Integration tests for SandboxExtension structured logging with real FFI.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/sandbox_logging_test.dart
/// ```
void main() {
  late MemorySink sink;
  late LogLevel previousLevel;

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

  late Monty pool;

  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  Future<MontyBridge> createBridge() async => MontyBridge(
    session: await pool.checkout(),
    logger: StructLogBridgeLogger.root(LogManager.instance),
  );

  group('sandbox logging with real FFI', () {
    test('spawn + await logs full lifecycle', () async {
      final bridge = await createBridge();
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      await registry.attachTo(bridge);

      final plugin = registry.extensions.whereType<SandboxExtension>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final await_ = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_await')
          .handler;

      final handle = (await spawn!({'code': '2 + 3'}, _testCtx))! as int;
      final result = await await_!({'handle': handle}, _testCtx);

      expect(result, 5);

      // Verify structured log records were emitted.
      final messages = sink.records.map((r) => r.message).toList();
      expect(messages, contains('Child bridge created'));
      expect(messages, contains('Child spawned'));
      expect(messages, contains('Child completed'));

      // Verify spawn record has structured attributes.
      final spawnRecord = sink.records.firstWhere(
        (r) => r.message == 'Child spawned',
      );
      expect(spawnRecord.attributes['childId'], handle);
      expect(spawnRecord.attributes['depth'], 0);

      bridge.dispose();
    });

    test('failed child logs error details', () async {
      final bridge = await createBridge();
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      await registry.attachTo(bridge);

      final plugin = registry.extensions.whereType<SandboxExtension>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final await_ = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_await')
          .handler;

      final handle =
          (await spawn!({'code': 'undefined_variable_xyz'}, _testCtx))! as int;

      try {
        await await_!({'handle': handle}, _testCtx);
      } on Exception {
        // Expected.
      }

      final failRecord = sink.records.firstWhere(
        (r) => r.message == 'Child failed',
      );
      expect(failRecord.level, LogLevel.debug);
      expect(failRecord.attributes['childId'], handle);
      expect(failRecord.attributes['error']! as String, contains('NameError'));

      bridge.dispose();
    });

    test('dispose logs child counts', () async {
      final bridge = await createBridge();
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      await registry.attachTo(bridge);

      final plugin = registry.extensions.whereType<SandboxExtension>().first;
      final spawn = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_spawn')
          .handler;
      final await_ = plugin.functions
          .firstWhere((f) => f.schema.name == 'sandbox_await')
          .handler;

      final handle = (await spawn!({'code': '42'}, _testCtx))! as int;
      await await_!({'handle': handle}, _testCtx);

      await plugin.onDispose();

      final disposeRecord = sink.records.firstWhere(
        (r) => r.message == 'Disposing SandboxExtension',
      );
      expect(disposeRecord.level, LogLevel.info);
      expect(disposeRecord.attributes['totalChildren'], 1);
      expect(disposeRecord.attributes['aliveChildren'], 0);

      bridge.dispose();
    });
  });
}
