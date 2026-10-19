// Integration test for type checking on core 0.110: a session checked out
// with `typeCheck: true` rejects a snippet the check fails with
// MontyTypingError, and runs one it passes.
//
// Run: dart test --run-skipped --tags=integration -p vm
//        test/integration/monty_type_check_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;

  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  /// Feeds [code] on a fresh type-checking session; returns the typing
  /// error's diagnostics, or null when the snippet passed the check. A
  /// snippet that passes then runs, so a runtime error (a stub has no
  /// body to call) still counts as passing.
  Future<String?> typeCheck(
    String code, {
    String? stubs,
    String scriptName = 'main.py',
  }) => pool.withSession(
    (session) async {
      try {
        await session.feedRun(code);

        return null;
      } on MontyTypingError catch (e) {
        return e.display();
      } on MontyRuntimeError {
        return null;
      }
    },
    typeCheck: true,
    typeCheckStubs: stubs,
    scriptName: scriptName,
  );

  group('type checking', () {
    test('passes clean code', () async {
      expect(await typeCheck('x: int = 1\ny: str = "hello"'), isNull);
    });

    test('flags a type-incompatible assignment', () async {
      final diagnostics = await typeCheck('x: int = "not an int"');
      expect(diagnostics, isNotNull);
      expect(diagnostics, contains('invalid-assignment'));
    });

    test('stub declarations are visible to the checker', () async {
      const stub = 'def fetch(url: str) -> str: ...';
      const code = 'result: str = fetch("https://example.com")';

      // Without the stub, fetch is unresolved and surfaces a diagnostic.
      expect(await typeCheck(code), isNotNull);
      // With it, the snippet type-checks cleanly.
      expect(await typeCheck(code, stubs: stub), isNull);
    });

    test('real type errors surface even with stubs', () async {
      const stub = 'def fetch(url: str) -> str: ...';
      final diagnostics = await typeCheck(
        'result: int = fetch("https://example.com")',
        stubs: stub,
      );
      expect(diagnostics, contains('invalid-assignment'));
    });

    test('scriptName surfaces in the diagnostics', () async {
      final diagnostics = await typeCheck(
        'x: int = "oops"',
        scriptName: 'agent.py',
      );
      expect(diagnostics, contains('agent.py'));
    });
  });
}
