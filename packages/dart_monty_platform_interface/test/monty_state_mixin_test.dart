import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Test harness that exposes protected [MontyStateMixin] members publicly.
class _TestStateMachine with MontyStateMixin {
  @override
  String get backendName => 'TestBackend';

  void doAssertNotDisposed(String method) => assertNotDisposed(method);
  void doAssertIdle(String method) => assertIdle(method);
  void doAssertActive(String method) => assertActive(method);
  void doMarkActive() => markActive();
  void doMarkIdle() => markIdle();
  void doMarkDisposed() => markDisposed();
  void doRejectInputs(Map<String, Object?>? inputs) => rejectInputs(inputs);
}

void main() {
  late _TestStateMachine sm;

  setUp(() {
    sm = _TestStateMachine();
  });

  group('initial state', () {
    test('starts idle', () {
      expect(sm.isIdle, isTrue);
      expect(sm.isActive, isFalse);
      expect(sm.isDisposed, isFalse);
    });
  });

  group('guard assertions', () {
    test('assertNotDisposed passes when idle', () {
      expect(() => sm.doAssertNotDisposed('run'), returnsNormally);
    });

    test('assertNotDisposed passes when active', () {
      sm.doMarkActive();
      expect(() => sm.doAssertNotDisposed('resume'), returnsNormally);
    });

    test('assertNotDisposed throws when disposed', () {
      sm.doMarkDisposed();
      expect(
        () => sm.doAssertNotDisposed('run'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TestBackend'),
          ),
        ),
      );
    });

    test('assertIdle passes when idle', () {
      expect(() => sm.doAssertIdle('run'), returnsNormally);
    });

    test('assertIdle passes when disposed', () {
      sm.doMarkDisposed();
      expect(() => sm.doAssertIdle('run'), returnsNormally);
    });

    test('assertIdle throws when active', () {
      sm.doMarkActive();
      expect(
        () => sm.doAssertIdle('run'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('while execution is active'),
          ),
        ),
      );
    });

    test('assertActive passes when active', () {
      sm.doMarkActive();
      expect(() => sm.doAssertActive('resume'), returnsNormally);
    });

    test('assertActive throws when idle', () {
      expect(
        () => sm.doAssertActive('resume'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not in active state'),
          ),
        ),
      );
    });

    test('assertActive throws when disposed', () {
      sm.doMarkDisposed();
      expect(
        () => sm.doAssertActive('resume'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('state transitions', () {
    test('markActive transitions to active', () {
      sm.doMarkActive();
      expect(sm.isActive, isTrue);
      expect(sm.isIdle, isFalse);
      expect(sm.isDisposed, isFalse);
    });

    test('markIdle transitions to idle', () {
      sm
        ..doMarkActive()
        ..doMarkIdle();
      expect(sm.isIdle, isTrue);
      expect(sm.isActive, isFalse);
    });

    test('markDisposed transitions to disposed', () {
      sm.doMarkDisposed();
      expect(sm.isDisposed, isTrue);
      expect(sm.isIdle, isFalse);
      expect(sm.isActive, isFalse);
    });
  });

  group('rejectInputs', () {
    test('accepts null inputs', () {
      expect(() => sm.doRejectInputs(null), returnsNormally);
    });

    test('accepts empty map', () {
      expect(() => sm.doRejectInputs({}), returnsNormally);
    });

    test('throws for non-empty map', () {
      expect(
        () => sm.doRejectInputs({'a': 1}),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('TestBackend'),
          ),
        ),
      );
    });
  });

  group('full lifecycle', () {
    test('idle -> active -> idle -> active -> disposed', () {
      expect(sm.isIdle, isTrue);

      sm.doMarkActive();
      expect(sm.isActive, isTrue);

      sm.doMarkIdle();
      expect(sm.isIdle, isTrue);

      sm.doMarkActive();
      expect(sm.isActive, isTrue);

      sm.doMarkDisposed();
      expect(sm.isDisposed, isTrue);

      expect(() => sm.doAssertNotDisposed('run'), throwsStateError);
      expect(() => sm.doAssertActive('resume'), throwsStateError);
    });
  });

  group('error messages contain backendName', () {
    test('assertNotDisposed message', () {
      sm.doMarkDisposed();
      expect(
        () => sm.doAssertNotDisposed('run'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Cannot call run() on a disposed TestBackend',
          ),
        ),
      );
    });

    test('rejectInputs message', () {
      expect(
        () => sm.doRejectInputs({'key': 'value'}),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            startsWith('The TestBackend backend'),
          ),
        ),
      );
    });
  });
}
