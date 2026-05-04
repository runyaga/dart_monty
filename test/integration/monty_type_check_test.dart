// Integration test for Monty.typeCheck via the FFI backend.
//
// Run: dart test --run-skipped --tags=integration -p vm \
//        test/integration/monty_type_check_test.dart
//
// WASM coverage for Monty.typeCheck lives in dart_monty_core's own test
// suite (the JS bridge + worker round-trip). dart_monty re-exports the
// symbol unchanged, so we only need to confirm it dispatches correctly
// through the FFI path.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  group('Monty.typeCheck', () {
    test('returns no diagnostics for clean code', () async {
      final errors = await Monty.typeCheck('x: int = 1\ny: str = "hello"');
      expect(errors, isEmpty);
    });

    test('flags type-incompatible assignment', () async {
      final errors = await Monty.typeCheck('x: int = "not an int"');
      expect(errors, isNotEmpty);
      final first = errors.first;
      expect(first.line, 1);
      expect(first.code, isNotEmpty);
      expect(first.message, isNotEmpty);
    });

    test('prefixCode declarations are visible to the checker', () async {
      const stub = 'def fetch(url: str) -> str: return ""';

      // Without prefixCode, fetch is unresolved and surfaces a diagnostic.
      final without = await Monty.typeCheck(
        'result: str = fetch("https://example.com")',
      );
      expect(without, isNotEmpty);

      // With prefixCode, the snippet type-checks cleanly.
      final withStub = await Monty.typeCheck(
        'result: str = fetch("https://example.com")',
        prefixCode: stub,
      );
      expect(withStub, isEmpty);
    });

    test('real type errors surface even when prefixCode is supplied', () async {
      const stub = 'def fetch(url: str) -> str: return ""';
      final errors = await Monty.typeCheck(
        'result: int = fetch("https://example.com")',
        prefixCode: stub,
      );
      expect(errors, isNotEmpty);
      // Line 2 because prefixCode shifts user code down by one line worth
      // of the stub — but the diagnostic tracks the user-code position;
      // confirm the column reflects the assignment, not the stub line.
      expect(errors.any((e) => e.code.contains('assignment')), isTrue);
    });

    test('scriptName surfaces in diagnostic path', () async {
      final errors = await Monty.typeCheck(
        'x: int = "oops"',
        scriptName: 'agent.py',
      );
      expect(errors, isNotEmpty);
      expect(errors.first.path, contains('agent.py'));
    });
  });
}
