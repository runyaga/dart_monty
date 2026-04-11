import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:test/test.dart';

import '../ffi/mock_native_bindings.dart';

void main() {
  group('ReplSession (unit)', () {
    late MockNativeBindings mock;

    setUp(() {
      mock = MockNativeBindings();
    });

    test('construction does not throw', () {
      final bindings = FfiReplBindings(bindings: mock);
      final repl = MontyRepl.withBindings(bindings: bindings);
      final session = ReplSession.withRepl(repl: repl);
      expect(session, isNotNull);
    });

    test('dispose is idempotent', () async {
      final bindings = FfiReplBindings(bindings: mock);
      final repl = MontyRepl.withBindings(bindings: bindings);
      final session = ReplSession.withRepl(repl: repl);
      await session.dispose();
      await session.dispose();
    });

    test('dispose after use does not throw', () async {
      final bindings = FfiReplBindings(bindings: mock);
      final repl = MontyRepl.withBindings(bindings: bindings);
      final session = ReplSession.withRepl(repl: repl);

      // Trigger creation
      await repl.feed('1');

      await session.dispose();
    });

    test('withRepl accepts plugins', () {
      final bindings = FfiReplBindings(bindings: mock);
      final repl = MontyRepl.withBindings(bindings: bindings);
      final session = ReplSession.withRepl(
        repl: repl,
        plugins: const [],
      );
      expect(session, isNotNull);
    });
  });
}
