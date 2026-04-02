@Tags(['integration'])
library;

import 'dart:async';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// T1-3: Terminate Resource Release
///
/// Verifies that terminate() frees ALL resources: the Rust MontyHandle
/// (via freeById), the handleId reference, and the isolate.
/// Polls for [isolate.handleId] to become non-null within [timeout].
Future<int> _waitForHandleId(
  NativeIsolateBindingsImpl isolate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (isolate.handleId == null) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('handleId not set within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return isolate.handleId!;
}

void main() {
  const infiniteLoop = 'while True: pass';

  // Pre-load native library so trial 1 doesn't timeout on cold start.
  setUpAll(() async {
    final warmUp = NativeIsolateBindingsImpl();
    await warmUp.init();
    await warmUp.run('1');
    await warmUp.dispose();
  });

  group('terminate resource cleanup', () {
    for (var trial = 1; trial <= 5; trial++) {
      test('trial $trial: terminate frees Rust registry entry', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        final hid = await _waitForHandleId(isolate);
        expect(hid, greaterThan(0));

        // Before terminate: handle exists in Rust registry.
        final preState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        expect(preState, isNotNull, reason: 'handle should be in registry');

        // Guard startFuture so its error does not escape the test zone
        // during the terminate() await.
        Object? startError;
        unawaited(
          startFuture.then<void>(
            (_) {},
            onError: (Object e) {
              startError = e;
            },
          ),
        );

        await isolate.terminate();

        expect(
          startError,
          anyOf(isA<MontyCancelledError>(), isA<MontyException>()),
        );

        // After terminate: handleId should be null on the Dart side.
        expect(isolate.handleId, isNull);

        // After terminate: Rust registry should not contain the handle.
        final postState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        expect(
          postState,
          isNull,
          reason: 'handle should be freed from Rust registry',
        );
      });
    }
  });

  group('zombie tracking', () {
    test('zombie count starts at zero or a known baseline', () {
      // Just verify the static counter is accessible. It should be zero
      // if no tests have triggered zombie conditions.
      expect(NativeIsolateBindingsImpl.zombieCount, greaterThanOrEqualTo(0));
    });
  });
}
