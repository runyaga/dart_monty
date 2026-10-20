@Tags(['integration'])
library;

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';

late HostContext _testCtx;

/// Integration tests for SandboxExtension structured logging with real FFI.
///
/// Run with:
/// ```bash
/// dart test --tags=integration --run-skipped \
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

  setUpAll(
    () async => pool = await Monty.start(
      workerLocation: acceptanceWorkerLocation,
      checkoutTimeout: const Duration(seconds: 5),
    ),
  );
  tearDownAll(() => pool.close());

  Future<MontyRuntime> createBridge(List<MontyExtension> extensions) async {
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: extensions,
    );
    addTearDown(runtime.dispose);
    await runtime.invoke('sandbox_await_all', {'handles': const MontyList([])});
    _testCtx = HostContext(
      emit: (_) {
        // These tests assert on log records, not emitted events.
      },
      executionId: 'test',
      parent: runtime,
    );

    return runtime;
  }

  group('sandbox logging with real FFI', () {
    test('spawn + await logs full lifecycle', () async {
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      final plugin = registry.extensions
          .whereType<SandboxExtension>()
          .firstOrNull;
      if (plugin == null) {
        fail('SandboxExtension not registered');
      }
      final spawn = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_spawn')
          ?.handler;
      final await_ = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_await')
          ?.handler;

      final handle =
          (await spawn!({'code': const MontyString('2 + 3')}, _testCtx))
              as MontyInt;
      final result = await await_!({
        'handle': MontyValue.fromDart(handle),
      }, _testCtx);

      expect(result, const MontyInt(5));

      // Verify structured log records were emitted.
      final messages = sink.records.map((r) => r.message).toList();
      expect(messages, contains('Child bridge created'));
      expect(messages, contains('Child spawned'));
      expect(messages, contains('Child completed'));

      // Verify spawn record has structured attributes.
      final spawnRecord = sink.records.firstWhereOrNull(
        (r) => r.message == 'Child spawned',
      );
      expect(spawnRecord?.attributes['childId'], handle.value);
      expect(spawnRecord?.attributes['depth'], 0);

      await bridge.dispose();
    });

    test('failed child logs error details', () async {
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      final plugin = registry.extensions
          .whereType<SandboxExtension>()
          .firstOrNull;
      if (plugin == null) {
        fail('SandboxExtension not registered');
      }
      final spawn = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_spawn')
          ?.handler;
      final await_ = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_await')
          ?.handler;

      final handle =
          (await spawn!({
                'code': const MontyString('undefined_variable_xyz'),
              }, _testCtx))
              as MontyInt;

      try {
        await await_!({'handle': MontyValue.fromDart(handle)}, _testCtx);
      } on Exception {
        // Expected.
      }

      final failRecord = sink.records.firstWhereOrNull(
        (r) => r.message == 'Child failed',
      );
      expect(failRecord?.level, LogLevel.debug);
      expect(failRecord?.attributes['childId'], handle.value);
      expect(
        failRecord?.attributes['error']!! as String,
        contains('NameError'),
      );

      await bridge.dispose();
    });

    test('dispose logs child counts', () async {
      final registry = ExtensionCoordinator()
        ..register(
          SandboxExtension(),
        );
      final bridge = await createBridge(registry.extensions);

      final plugin = registry.extensions
          .whereType<SandboxExtension>()
          .firstOrNull;
      if (plugin == null) {
        fail('SandboxExtension not registered');
      }
      final spawn = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_spawn')
          ?.handler;
      final await_ = plugin.functions
          .firstWhereOrNull((f) => f.schema.name == 'sandbox_await')
          ?.handler;

      final handle =
          (await spawn!({'code': const MontyString('42')}, _testCtx))
              as MontyInt;
      await await_!({'handle': MontyValue.fromDart(handle)}, _testCtx);

      await plugin.onDispose();

      final disposeRecord = sink.records.firstWhereOrNull(
        (r) => r.message == 'Disposing SandboxExtension',
      );
      expect(disposeRecord?.level, LogLevel.info);
      expect(disposeRecord?.attributes['totalChildren'], 1);
      expect(disposeRecord?.attributes['aliveChildren'], 0);

      await bridge.dispose();
    });
  });
}
