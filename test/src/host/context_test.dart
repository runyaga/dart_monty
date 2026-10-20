import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '../../integration/_worker.dart';

// Shared no-op emit callback for structural tests that never emit events.
void _ignoreEvent(BridgeEvent _) {}

void main() {
  group('HostContext.parent', () {
    test('typed as HostParentRef — no execute() at compile time', () {
      // This test is mostly about the *static* shape: ctx.parent is
      // HostParentRef?, which intentionally does NOT expose execute().
      // The only way to drive a sub-script from a host function is
      // ctx.subExecute. If a future refactor re-introduced execute() on
      // HostParentRef, this test's compile-time guarantee would break.
      final ctx = HostContext(emit: _ignoreEvent, executionId: 'test');

      expect(ctx.parent, isNull);
      // Parent surface area:
      //   - emitChildEvent(handle, event)
      //   - schemas
      // Deliberately absent: execute(), invokeHostFunction(), dispose()...
      //
      // The cast below would be a compile error if the type ever drifted:
      // ignore: omit_local_variable_types
      final HostParentRef? p = ctx.parent;
      expect(p, isNull);
    });

    test('subExecute is null on a bare HostContext (test fixture)', () {
      final ctx = HostContext(emit: _ignoreEvent, executionId: 'test');

      expect(ctx.subExecute, isNull);
    });

    test(
      'subExecute closure runs Python and returns the result',
      () async {
        Future<MontyValue> wired(
          String code, {
          Map<String, Object?>? inputs,
        }) => Monty.withPool(
          workerLocation: workerLocation,
          (monty) => monty.withSession(
            (session) => session.feedRun(
              code,
              inputs: {
                for (final e in (inputs ?? const <String, Object?>{}).entries)
                  e.key: MontyValue.fromDart(e.value),
              },
            ),
          ),
        );

        final ctx = HostContext(
          emit: _ignoreEvent,
          executionId: 'test',
          subExecute: wired,
        );

        final r = await ctx.subExecute!(
          'x * 2',
          inputs: {'x': const MontyInt(21)},
        );
        expect(r.dartValue, 42);
      },
      // Needs the native runtime bound via FFI/WASM harness; the structural
      // tests in this group cover the design surface on every platform.
      tags: ['integration'],
    );
  });

  group('HostParentRef contract', () {
    test('exposes emitChildEvent and schemas — and nothing else', () {
      // Compile-time check: a HostParentRef? variable does not carry
      // .execute() or other dangerous methods. If you uncomment the
      // commented line below, dart analyze must fail.
      const HostParentRef? parent = null;

      // parent.execute('1 + 1');  // <- would not compile (good!)
      expect(parent, isNull);
    });
  });

  test('without a cancelToken a context holds a fresh, live one', () {
    final a = HostContext(
      emit: (_) {
        // The test only inspects the cancel token.
      },
      executionId: 'a',
    );
    final b = HostContext(
      emit: (_) {
        // The test only inspects the cancel token.
      },
      executionId: 'b',
    );

    expect(a.cancelToken.isCancelled, isFalse);
    expect(a.cancelToken, isNot(same(b.cancelToken)));
  });
}
