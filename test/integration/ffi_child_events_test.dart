// MontyRuntime.emitChildEvent — through the SANDBOX path that calls it.
//
// This was the last of dart_monty's two api-exercised exceptions (4b5c7b4).
// test/src/bridge/monty_runtime_child_events_test.dart calls emitChildEvent
// DIRECTLY on a runtime, which proves the method forwards what it is handed.
// It cannot prove the thing that matters: that a real spawned child's events
// reach a real parent. The only production caller is sandbox.dart:696,
// `parent?.emitChildEvent(childHandle, event)`, and `parent` arrives through
// HostContext — set by host/dispatch.dart:284 from the MontyRuntime that owns
// the bridge. A null anywhere on that chain makes the call a silent no-op,
// and a unit test that supplies the runtime itself cannot see it.
//
// So these drive Python `sandbox_spawn(...)` on FFI and watch the PARENT's
// stream.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

MontyPlatform _platform() => MontyFfi(bindings: const NativeBindingsFfi());

MontyRuntime _runtimeWithSandbox() => MontyRuntime(
  extensions: [SandboxExtension(platformFactory: () async => _platform())],
);

/// Child events are delivered asynchronously relative to `execute().result`,
/// so settle the microtask/event queue before asserting on them.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  group('emitChildEvent through a real sandbox spawn (FFI)', () {
    test("a spawned child's events reach the parent stream", () async {
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      final result = await runtime
          .execute(
            r'sandbox_spawn(code="y = 2\ny")',
          )
          .result;
      await _settle();

      expect(result.error, isNull);
      expect(
        children,
        isNotEmpty,
        reason: 'sandbox.dart:696 must have reached a non-null parent',
      );
    });

    test('the childHandle matches the handle sandbox_spawn returned', () async {
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      final result = await runtime
          .execute(
            r'sandbox_spawn(code="y = 2\ny")',
          )
          .result;
      await _settle();

      // The handle Python got back and the handle the events are tagged with
      // have to be the same value, or a caller cannot correlate them — which
      // is the entire purpose of tagging.
      final handle = '${result.value.dartValue}';
      expect(children.map((e) => e.childHandle).toSet(), {handle});
    });

    test("the inner payloads are the CHILD's run lifecycle", () async {
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      await runtime.execute(r'sandbox_spawn(code="y = 2\ny")').result;
      await _settle();

      // Wrapping is not enough: the payload must be the child's own events,
      // in order. A parent that re-emitted its OWN run events under a child
      // handle would satisfy the two cases above and fail this one.
      final inner = children.map((e) => e.inner.runtimeType.toString());
      expect(
        inner,
        containsAllInOrder(['BridgeRunStarted', 'BridgeRunFinished']),
      );
    });

    test('a run that spawns nothing emits NO child events', () async {
      // The control. Without it, a runtime that tagged every event as a child
      // event would pass everything above.
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      final result = await runtime.execute('1 + 1').result;
      await _settle();

      expect(result.value.dartValue, 2);
      expect(children, isEmpty);
    });

    test('the direct call and the sandbox path wrap identically', () async {
      // Calls emitChildEvent BY NAME on a runtime that is simultaneously
      // wired to a real backend, and checks the envelope matches what the
      // spawn path produced above. Two reasons this case exists rather than
      // resting on the end-to-end tests:
      //
      //   1. tool/check_api_exercised.sh matches the call textually, and the
      //      spawn cases never write the name — Python does. Before comments
      //      were stripped from that search, this file's own HEADER COMMENT
      //      was satisfying the check, which is exactly the kind of false
      //      coverage it exists to catch.
      //   2. it is real information: if the two paths ever disagreed about
      //      the envelope, a consumer correlating by childHandle would break
      //      for one of them only.
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      const inner = BridgeRunStarted(threadId: 't', runId: 'r');
      runtime.emitChildEvent('7', inner);
      await _settle();

      expect(children, hasLength(1));
      expect(children.single.childHandle, '7');
      expect(
        identical(children.single.inner, inner),
        isTrue,
        reason: 'the payload must be forwarded, not reconstructed',
      );
    });

    test('two children get distinct handles', () async {
      final runtime = _runtimeWithSandbox();
      addTearDown(runtime.dispose);

      final children = <BridgeChildEvent>[];
      final sub = runtime.events.listen((e) {
        if (e is BridgeChildEvent) children.add(e);
      });
      addTearDown(sub.cancel);

      await runtime.execute(r'sandbox_spawn(code="a = 1\na")').result;
      await runtime.execute(r'sandbox_spawn(code="b = 2\nb")').result;
      await _settle();

      // If the handle were constant, correlation would be impossible the
      // moment two children are alive at once.
      expect(children.map((e) => e.childHandle).toSet(), hasLength(2));
    });
  });
}
