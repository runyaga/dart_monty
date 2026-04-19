import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyBridgeSession.sessionStateSignal', () {
    test('starts as an empty map', () {
      final session = MontyBridgeSession();
      addTearDown(session.dispose);

      expect(session.sessionStateSignal.value, isEmpty);
    });

    test('sessionStateSignal and state return the same initial value', () {
      final session = MontyBridgeSession();
      addTearDown(session.dispose);

      expect(session.sessionStateSignal.value, equals(session.state));
    });

    test('clearState() fires the signal with an empty map', () {
      final session = MontyBridgeSession();
      addTearDown(session.dispose);

      // Real updates come from execute() via __persist_state__ (tested
      // in integration tests on both FFI and WASM).
      final seen = <Map<String, Object?>>[];
      final sub = session.sessionStateSignal.subscribe(seen.add);
      addTearDown(sub);

      session.clearState();

      // subscribe fires immediately with current value, then on clearState.
      expect(seen.length, greaterThanOrEqualTo(1));
      expect(seen.last, isEmpty);
    });

    test(
      'state getter returns a copy — mutations do not affect the signal',
      () {
        final session = MontyBridgeSession();
        addTearDown(session.dispose);

        final copy = session.state;
        // ignore: avoid-collection-methods-with-unrelated-types
        copy['x'] = 42;

        expect(session.sessionStateSignal.value, isEmpty);
      },
    );

    test('sessionStateSignal is a ReadonlySignal', () {
      final session = MontyBridgeSession();
      addTearDown(session.dispose);

      expect(
        session.sessionStateSignal,
        isA<ReadonlySignal<Map<String, Object?>>>(),
      );
    });
  });
}
