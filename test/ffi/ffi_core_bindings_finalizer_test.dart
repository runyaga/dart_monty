/// Unit test for #271: NativeFinalizer detach token must survive GC.
///
/// This test creates and disposes multiple FfiCoreBindings instances in
/// rapid succession, then forces GC. Without the fix (using guard as
/// detach token), a stale finalizer would call monty_free on a reused
/// address, corrupting the next handle. With the fix (separate Object
/// token), detach works reliably.
///
/// Does NOT require network — uses only sync host functions.
library;

// Unit test uses print for progress output.
// ignore_for_file: avoid_print
import 'dart:developer' as developer;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('FfiCoreBindings finalizer safety (#271)', () {
    test('20 create/start/free cycles then one execute', () async {
      // Rapidly create and destroy handles to pressure GC and trigger
      // finalizer race. Each cycle: create handle → start → free.
      for (var i = 0; i < 20; i++) {
        final session = AgentSession();
        await session.execute('1 + 1');
        await session.dispose();
      }

      // Force GC to flush any pending finalizers.
      // NativeFinalizer callbacks run on GC, so we need to trigger it.
      for (var i = 0; i < 5; i++) {
        // Allocate garbage to encourage GC.
        List.generate(100000, (i) => Object());
        await Future<void>.delayed(Duration.zero);
      }
      developer.NativeRuntime.writeHeapSnapshotToFile('/dev/null');

      // Now create a session and do real work.
      // Before the fix: stale finalizer freed this handle → crash.
      final session = AgentSession()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'test_fn',
              description: 'test',
            ),
            handler: (_) async => 'alive',
          ),
        );
      final r = await session.execute('test_fn()');
      await session.dispose();

      expect(r.value?.dartValue, 'alive');
      print('  handle survived 20 prior disposals + GC pressure');
    });

    test('dispose does not leave dangling finalizer', () async {
      // Create a session, use it, dispose it.
      final s1 = AgentSession();
      await s1.execute('x = 42');
      await s1.dispose();

      // Create another at potentially the same handle address.
      final s2 = AgentSession();
      await s2.execute('y = 99');

      // Force GC — if s1's finalizer is still live, it frees s2's handle.
      for (var i = 0; i < 5; i++) {
        List.generate(100000, (i) => Object());
        await Future<void>.delayed(Duration.zero);
      }

      // s2 should still work after GC.
      final r = await s2.execute('y');
      await s2.dispose();

      expect(r.value?.dartValue, 99);
      print('  s2 survived GC after s1 disposal');
    });

    test('100 rapid session cycles', () async {
      for (var i = 0; i < 100; i++) {
        final s = AgentSession();
        final r = await s.execute('$i * 2');
        expect(r.value?.dartValue, i * 2);
        await s.dispose();
      }
      print('  100/100 rapid cycles passed');
    });
  });
}
