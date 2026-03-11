import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:dart_monty_platform_interface/monty_backend_spi.dart';
import 'package:test/test.dart';

/// T1-4: Sealed Error Routing Boundary
///
/// Verifies that each distinct failure mode maps to its correct sealed
/// MontyError subtype via BaseMontyPlatform._throwSealedErrorIfApplicable.
void main() {
  group('sealed error routing', () {
    test('KeyboardInterrupt maps to MontyCancelledError', () async {
      final bindings = _FakeCoreBindings();
      final platform = _TestPlatform(bindings: bindings);

      bindings.nextRunResult = const CoreRunResult(
        ok: false,
        error: 'Execution cancelled',
        excType: 'KeyboardInterrupt',
      );

      await expectLater(
        platform.run('code'),
        throwsA(isA<MontyCancelledError>()),
      );
    });

    test('MemoryLimitExceeded maps to MontyResourceError', () async {
      final bindings = _FakeCoreBindings();
      final platform = _TestPlatform(bindings: bindings);

      bindings.nextRunResult = const CoreRunResult(
        ok: false,
        error: 'Memory limit exceeded',
        excType: 'MemoryLimitExceeded',
      );

      await expectLater(
        platform.run('code'),
        throwsA(isA<MontyResourceError>()),
      );
    });

    test(
      'Python ZeroDivisionError maps to MontyException (not sealed)',
      () async {
        final bindings = _FakeCoreBindings();
        final platform = _TestPlatform(bindings: bindings);

        bindings.nextRunResult = const CoreRunResult(
          ok: false,
          error: 'division by zero',
          excType: 'ZeroDivisionError',
        );

        await expectLater(
          platform.run('code'),
          throwsA(
            isA<MontyException>().having(
              (e) => e.excType,
              'excType',
              'ZeroDivisionError',
            ),
          ),
        );
      },
    );

    test(
      'progress error with KeyboardInterrupt maps to MontyCancelledError',
      () async {
        final bindings = _FakeCoreBindings();
        final platform = _TestPlatform(bindings: bindings);

        bindings.nextStartResult = const CoreProgressResult(
          state: 'error',
          error: 'Execution cancelled',
          excType: 'KeyboardInterrupt',
        );

        await expectLater(
          platform.start('code'),
          throwsA(isA<MontyCancelledError>()),
        );
      },
    );

    test(
      'progress error with MemoryLimitExceeded maps to MontyResourceError',
      () async {
        final bindings = _FakeCoreBindings();
        final platform = _TestPlatform(bindings: bindings);

        bindings.nextStartResult = const CoreProgressResult(
          state: 'error',
          error: 'Memory limit exceeded',
          excType: 'MemoryLimitExceeded',
        );

        await expectLater(
          platform.start('code'),
          throwsA(isA<MontyResourceError>()),
        );
      },
    );
  });

  group('exhaustive switch compiles', () {
    test('all 6 sealed subtypes are matchable', () {
      // This test verifies that the sealed class hierarchy compiles
      // with exhaustive pattern matching.
      const errors = <MontyError>[
        MontyCancelledError(),
        MontyScriptError('test'),
        MontyPanicError('test'),
        MontyCrashError(),
        MontyDisposedError(),
        MontyResourceError('test'),
      ];

      for (final error in errors) {
        final label = switch (error) {
          MontyCancelledError() => 'cancelled',
          MontyScriptError() => 'script',
          MontyPanicError() => 'panic',
          MontyCrashError() => 'crash',
          MontyDisposedError() => 'disposed',
          MontyResourceError() => 'resource',
        };
        expect(label, isNotEmpty);
      }
    });

    test('MontyScriptError preserves excType', () {
      const error = MontyScriptError(
        'division by zero',
        excType: 'ZeroDivisionError',
      );
      expect(error.excType, 'ZeroDivisionError');
      expect(error.message, 'division by zero');
    });
  });

  group('MontyError toString coverage', () {
    test('MontyCancelledError default message', () {
      const e = MontyCancelledError();
      expect(e.toString(), 'MontyCancelledError: Execution cancelled');
    });

    test('MontyCancelledError custom message', () {
      const e = MontyCancelledError('custom');
      expect(e.toString(), 'MontyCancelledError: custom');
    });

    test('MontyScriptError toString', () {
      const e = MontyScriptError('boom', excType: 'ValueError');
      expect(e.toString(), 'MontyScriptError: boom');
    });

    test('MontyPanicError toString', () {
      const e = MontyPanicError('rust panic');
      expect(e.toString(), 'MontyPanicError: rust panic');
    });

    test('MontyCrashError default message', () {
      const e = MontyCrashError();
      expect(e.toString(), 'MontyCrashError: Interpreter crashed unexpectedly');
    });

    test('MontyDisposedError default message', () {
      const e = MontyDisposedError();
      expect(
        e.toString(),
        'MontyDisposedError: Interpreter disposed during execution',
      );
    });

    test('MontyResourceError toString', () {
      const e = MontyResourceError('OOM');
      expect(e.toString(), 'MontyResourceError: OOM');
    });
  });

  group('MontyCancelToken', () {
    tearDown(() {
      // Reset native callbacks.
      MontyCancelRegistry.registerNativeCancel(
        cancelById: (_) => false,
        isCancelledById: (_) => null,
        ensureInitialized: ([_]) {},
      );
    });

    test('cancel delegates to MontyCancelRegistry.cancelById', () {
      var cancelledId = -1;
      MontyCancelRegistry.registerNativeCancel(
        cancelById: (id) {
          cancelledId = id;
          return true;
        },
        isCancelledById: (_) => false,
        ensureInitialized: ([_]) {},
      );
      const token = MontyCancelToken(42);
      final result = token.cancel();
      expect(result, isTrue);
      expect(cancelledId, 42);
    });

    test('isAlive delegates to MontyCancelRegistry.isHandleAlive', () {
      MontyCancelRegistry.registerNativeCancel(
        cancelById: (_) => false,
        isCancelledById: (id) => id == 7 ? false : null,
        ensureInitialized: ([_]) {},
      );
      expect(const MontyCancelToken(7).isAlive, isTrue);
      expect(const MontyCancelToken(999).isAlive, isFalse);
    });
  });

  group('MontyPlatform default implementations', () {
    test('handleId returns null by default on MockMontyPlatform', () {
      final mock = MockMontyPlatform();
      // MockMontyPlatform's handleId defaults to null (delegates to super).
      expect(mock.handleId, isNull);
    });
  });

  group('cancel and handleId on MontyPlatform', () {
    test('cancel on mock platform', () async {
      final mock = MockMontyPlatform();
      await mock.cancel();
      expect(mock.cancelCalled, isTrue);
    });

    test('handleId on mock platform', () {
      final mock = MockMontyPlatform();
      expect(mock.handleId, isNull);
      mock.mockHandleId = 42;
      expect(mock.handleId, 42);
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class _FakeCoreBindings implements MontyCoreBindings {
  CoreRunResult nextRunResult = const CoreRunResult(ok: true, value: 4);
  CoreProgressResult nextStartResult = const CoreProgressResult(
    state: 'complete',
    value: 4,
  );

  @override
  Future<bool> init() async => true;

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async =>
      nextRunResult;

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async =>
      nextStartResult;

  @override
  Future<CoreProgressResult> resume(String valueJson) async =>
      const CoreProgressResult(state: 'complete');

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async =>
      const CoreProgressResult(state: 'complete');

  @override
  Future<CoreProgressResult> resumeAsFuture() async =>
      throw UnsupportedError('not supported');

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async =>
      throw UnsupportedError('not supported');

  @override
  Future<Uint8List> snapshot() async => Uint8List(0);

  @override
  Future<void> restoreSnapshot(Uint8List data) async {}

  @override
  Future<void> cancel() async {}

  @override
  int? get handleId => null;

  @override
  Future<void> dispose() async {}
}

class _TestPlatform extends BaseMontyPlatform {
  _TestPlatform({required super.bindings});

  @override
  String get backendName => 'test';
}
