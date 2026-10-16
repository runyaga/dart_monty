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
  for (final childLimits in [null, const ResourceLimits()]) {
    test('D3-child-limit-selection explicit=${childLimits != null}', () async {
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async => FakeMontySession(),
        limits: owning,
        extensions: [SandboxExtension(childLimits: childLimits)],
      );
      addTearDown(runtime.dispose);
      for (final override in ['timeout_ms', 'memory_bytes']) {
        final call = runtime.invoke('sandbox_spawn', {
          'code': const MontyString('42'),
          override: const MontyInt(200),
        });
        // Child execution remains D1-8. Reaching that stub proves explicit
        // null fields did not fall back field-by-field to the owner's caps.
        await expectLater(
          call,
          childLimits == null
              ? throwsArgumentError
              : throwsA(
                  isA<UnimplementedError>().having(
                    (e) => e.message,
                    'stub',
                    'D1-8',
                  ),
                ),
        );
      }
    });
  }
}
