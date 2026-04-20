import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Unit tests for `MontyRuntime.emitChildEvent`.
///
/// Asserts that child-plugin-originated events surface on the parent's
/// broadcast `events` stream wrapped in a [BridgeChildEvent], so observers
/// see a single attributed ordering across the ownership tree. Does not
/// spawn an actual child — [SandboxExtension] integration tests (FFI-tagged)
/// cover the end-to-end forwarding path.
void main() {
  group('MontyRuntime.emitChildEvent', () {
    test('wraps event in BridgeChildEvent tagged with handle', () async {
      final runtime = MontyRuntime(sandbox: true);
      final captured = <BridgeEvent>[];
      final sub = runtime.events.listen(captured.add);

      const inner = BridgeRunFinished(
        threadId: 't1',
        runId: 'r1',
        value: 99,
      );
      runtime.emitChildEvent('42', inner);

      await Future<void>.delayed(Duration.zero);

      expect(captured, hasLength(1));
      final event = captured.single;
      expect(event, isA<BridgeChildEvent>());
      event as BridgeChildEvent;
      expect(event.childHandle, '42');
      expect(event.inner, same(inner));

      await sub.cancel();
      await runtime.dispose();
    });

    test('is a no-op after dispose', () async {
      final runtime = MontyRuntime(sandbox: true);
      final captured = <BridgeEvent>[];
      final sub = runtime.events.listen(captured.add);
      await runtime.dispose();

      runtime.emitChildEvent(
        '0',
        const BridgeRunStarted(threadId: 't', runId: 'r'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(captured, isEmpty);
      await sub.cancel();
    });
  });
}
