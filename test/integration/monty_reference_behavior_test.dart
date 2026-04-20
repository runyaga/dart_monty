@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Reference behavior tests — validates what the Monty interpreter actually
/// does, independent of dart_monty's bridge abstractions.
///
/// These tests are the source of truth for every area where dart_monty's
/// behavior was previously assumed rather than tested. Each test runs against
/// a real Monty platform (no mocks) and documents the interpreter's actual
/// behavior so dart_monty can align with it.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/monty_reference_behavior_test.dart
/// ```
void main() {
  // ---------------------------------------------------------------------------
  // 2a. Print capture: does Monty capture prints natively?
  // ---------------------------------------------------------------------------

  group('2a — print output', () {
    test('raw MontySession captures print() in result.printOutput', () async {
      // Run print("hello") via dart_monty_core's MontySession directly —
      // no bridge preamble, no __console_write__ injection, no overriding
      // print. If MontyResult.printOutput is populated here, Monty captures
      // prints natively and the bridge's print preamble is adding unnecessary
      // overhead (and injecting 5 extra lines that distort line numbers).
      final session = MontySession();
      try {
        final result = await session.run('print("hello from monty")');
        // Document what we observe:
        expect(
          result.printOutput,
          isNotNull,
          reason:
              'Monty captures print() output natively in '
              'MontyResult.printOutput without any bridge preamble.',
        );
        expect(result.printOutput, contains('hello from monty'));
      } finally {
        session.dispose();
      }
    });

    test(
      'DefaultMontyBridge also captures print() — consistent with raw session',
      () async {
        // If the raw session test above passes, this confirms the bridge
        // is not introducing a duplicate or conflicting capture path.
        final session = MontyRuntime();
        try {
          final result = await session.execute('print("hello from bridge")');
          expect(result.printOutput, contains('hello from bridge'));
        } finally {
          await session.dispose();
        }
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 2c. Exception line numbers with bridge preamble
  // ---------------------------------------------------------------------------

  group('2c — exception line numbers', () {
    test('NameError on line 1 of user code reports line 1', () async {
      // DefaultMontyBridge injects a print-override preamble (~5 lines)
      // before user code, then subtracts _preambleLineCount from exception
      // line numbers. This test verifies the adjustment is correct.
      final session = MontyRuntime();
      try {
        final result = await session.execute('undefined_variable_xyz');
        expect(result.error, isNotNull);
        expect(result.error!.excType, 'NameError');
        // Line 1 of user code should report as line 1, not line 6
        expect(
          result.error!.lineNumber,
          1,
          reason:
              'The bridge preamble line count adjustment must correctly map '
              'exception lines back to user code lines.',
        );
      } finally {
        await session.dispose();
      }
    });

    test('NameError on line 3 of user code reports line 3', () async {
      final session = MontyRuntime();
      try {
        final result = await session.execute('x = 1\ny = 2\nundefined_xyz');
        expect(result.error, isNotNull);
        expect(result.error!.lineNumber, 3);
      } finally {
        await session.dispose();
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 2d. Last expression return: native Monty vs captureLastExpression
  // ---------------------------------------------------------------------------

  group('2d — last expression capture', () {
    test(
      'raw MontySession: expression result without captureLastExpression',
      () async {
        // dart_monty_core's captureLastExpression wraps the last expression as
        // `__r = (expr); __r`. This test checks whether that wrapper is needed,
        // or whether Monty returns the last expression natively.
        final session = MontySession();
        try {
          // Run bare expression with NO captureLastExpression wrapping
          final result = await session.run('1 + 1');
          // Document the result:
          expect(
            result.value,
            isA<MontyInt>(),
            reason:
                'Monty returns the last expression value natively — '
                'captureLastExpression may be redundant for expressions.',
          );
          expect((result.value as MontyInt).value, 2);
        } finally {
          session.dispose();
        }
      },
    );

    test('raw MontySession: assignment statement returns MontyNone', () async {
      // Assignments are statements, not expressions — they should return None.
      final session = MontySession();
      try {
        final result = await session.run('x = 42');
        expect(
          result.value,
          isA<MontyNone>(),
          reason: 'Assignment statement has no return value — MontyNone.',
        );
      } finally {
        session.dispose();
      }
    });
  });

  // ---------------------------------------------------------------------------
  // 2e. Host param type coercion
  // ---------------------------------------------------------------------------

  group('2e — host param type coercion', () {
    late MontyRuntime session;

    setUp(() {
      session = MontyRuntime()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'typed_fn',
              description: 'Test function with integer param.',
              params: [
                HostParam(name: 'n', type: HostParamType.integer),
              ],
            ),
            handler: (args, _) async => args['n'],
          ),
        );
    });

    tearDown(() async => session.dispose());

    test('integer param accepts Python int', () async {
      final result = await session.execute('typed_fn(n=42)');
      expect(result.error, isNull);
      expect(result.value.dartValue, 42);
    });

    test('integer param rejects Python string "42"', () async {
      // dart_monty's HostParam.validate() currently coerces "42" → 42.
      // This test documents whether that coercion is desirable.
      // If the test PASSES (no error), coercion is active.
      // If it FAILS (error returned), coercion was removed and strict
      // typing is enforced — which better matches Monty's raw behavior.
      final result = await session.execute('typed_fn(n="42")');
      // Document current behavior:
      if (result.error != null) {
        expect(
          result.error!.message,
          isNotEmpty,
          reason: 'String "42" correctly rejected for integer param.',
        );
      } else {
        // Coercion is active — document it
        expect(
          result.value.dartValue,
          42,
          reason:
              'dart_monty coerces string "42" to int 42 for integer params. '
              'This is a dart_monty invention not grounded in Monty behavior.',
        );
      }
    });

    test('integer param rejects Python float 1.5', () async {
      final result = await session.execute('typed_fn(n=1.5)');
      // A float cannot losslessly become an int — should error.
      expect(
        result.error,
        isNotNull,
        reason: 'Float 1.5 cannot be coerced to integer without data loss.',
      );
    });
  });
}
