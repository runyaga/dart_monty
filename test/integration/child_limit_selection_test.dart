@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

void main() {
  const owning = ResourceLimits(
    maxFeedDuration: Duration(milliseconds: 1),
    maxMemory: 100,
  );
  // Accepted explicit limits remain a D5-A gap until child checkout uses the
  // runtime seam. Rejection must not depend on the current checkout stub.
  test('D3-child-limit-selection omitted rejects owner escalation', () async {
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async => FakeMontySession(),
      limits: owning,
      extensions: [SandboxExtension()],
    );
    addTearDown(runtime.dispose);
    for (final override in ['timeout_ms', 'memory_bytes']) {
      await expectLater(
        runtime.invoke('sandbox_spawn', {
          'code': const MontyString('42'),
          override: const MontyInt(200),
        }),
        throwsArgumentError,
      );
    }
  });
}
