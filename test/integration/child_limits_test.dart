@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

// Accepted limits cannot be observed through the runtime checkout seam yet.
// Keep rejection witnesses here; accepted selection/reduction remains D5-A.
Future<MontyRuntime> _runtime(
  ResourceLimits? owner,
  ResourceLimits? child,
) async {
  final runtime = await startRuntimeWith(
    checkout: ({limits}) async => FakeMontySession(),
    limits: owner,
    extensions: [SandboxExtension(childLimits: child)],
  );
  addTearDown(runtime.dispose);

  return runtime;
}

Future<MontyValue> _spawn(MontyRuntime runtime, String field, int value) =>
    runtime.invoke('sandbox_spawn', {
      'code': const MontyString('42'),
      field: MontyInt(value),
    });

void main() {
  test('D5-omitted-whole-object-precheckout', () async {
    for (final owner in [
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 100),
        maxMemory: 200,
      ),
      const ResourceLimits(maxMemory: 200),
    ]) {
      final runtime = await _runtime(owner, null);
      await expectLater(
        _spawn(runtime, 'memory_bytes', 201),
        throwsArgumentError,
      );
      if (owner.maxFeedDuration != null) {
        await expectLater(
          _spawn(runtime, 'timeout_ms', 101),
          throwsArgumentError,
        );
      }
    }
  });

  test('D5-explicit-independent-precheckout', () async {
    const owner = ResourceLimits(
      maxFeedDuration: Duration(milliseconds: 10),
      maxMemory: 20,
    );
    final stricter = await _runtime(
      owner,
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 1),
        maxMemory: 2,
      ),
    );
    await expectLater(_spawn(stricter, 'timeout_ms', 10), throwsArgumentError);
    await expectLater(
      _spawn(stricter, 'memory_bytes', 20),
      throwsArgumentError,
    );
  });

  test('D5-guest-reject-precheckout', () async {
    final finite = await _runtime(
      null,
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 100),
        maxMemory: 100,
      ),
    );
    final unlimited = await _runtime(null, null);
    for (final field in ['timeout_ms', 'memory_bytes']) {
      for (final runtime in [finite, unlimited]) {
        await expectLater(_spawn(runtime, field, -1), throwsArgumentError);
      }
      await expectLater(_spawn(finite, field, 101), throwsArgumentError);
    }
  });
}
