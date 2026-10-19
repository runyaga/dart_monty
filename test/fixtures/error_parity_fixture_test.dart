@Tags(['cell'])
library;

import 'package:test/test.dart';

import 'error_parity.dart';

void main() {
  group('error parity fixture', () {
    test(
      'loads 32 cases with unique ids, expected steps, and exception types',
      () {
        expect(errorParityOracle, 'pydantic-monty 1.1.0');

        final cases = loadErrorParityCases();
        final ofAllCases = hasLength(32);
        expect(cases, ofAllCases);

        final ids = <String>{};
        var exceptionCount = 0;

        for (final testCase in cases) {
          expect(testCase.id, isNotEmpty);
          expect(
            ids.add(testCase.id),
            isTrue,
            reason: 'Duplicate case id: ${testCase.id}',
          );
          expect(
            testCase.expected,
            isNotEmpty,
            reason: 'Case ${testCase.id} must have at least one expected step',
          );

          for (final step in testCase.expected) {
            final exception = step.exception;
            if (exception != null) {
              exceptionCount++;
              expect(
                exception.type,
                isNotEmpty,
                reason: 'Expected exception in ${testCase.id} must have a type',
              );
            }
          }
        }

        expect(ids, ofAllCases);
        expect(exceptionCount, greaterThan(0));
      },
    );
  });
}
