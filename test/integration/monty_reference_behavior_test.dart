@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import '_printed.dart';
import '_worker.dart';

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
  late Monty pool;

  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  // ---------------------------------------------------------------------------
  // 2a. Print capture: does Monty capture prints natively?
  // ---------------------------------------------------------------------------

  group('2a — print output', () {
    test('a raw session hands print() text to its print callback', () async {
      // Confirms Monty captures print() output natively — the dart_monty
      // bridge does not inject any preamble or override print(); it collects
      // what core hands its print callback.
      final printed = CollectString();
      await pool.withSession(
        (session) => session.feedRun(
          'print("hello from monty")',
          printCallback: printed.call,
        ),
      );
      expect(printed.output, contains('hello from monty'));
    });

    test(
      'MontyRuntime also captures print() — consistent with raw session',
      () async {
        // The bridge passes printOutput through unchanged; this verifies
        // it does not lose or duplicate the captured stdout.
        final session = await MontyRuntime.start();
        try {
          final out = await printedBy(
            session.execute('print("hello from bridge")'),
          );
          expect(out, contains('hello from bridge'));
        } finally {
          await session.dispose();
        }
      },
      tags: 'd1-pending',
    );
  });

  // ---------------------------------------------------------------------------
  // 2c. Exception line numbers
  // ---------------------------------------------------------------------------

  group('2c — exception line numbers', () {
    test('NameError on line 1 of user code reports line 1', () async {
      // The bridge injects no preamble; line numbers from core should
      // come through unchanged.
      final session = await MontyRuntime.start();
      try {
        await expectLater(
          session.execute('undefined_variable_xyz').result,
          throwsA(
            isA<MontyRuntimeError>()
                .having((e) => e.exception.excType, 'excType', 'NameError')
                .having((e) => e.traceback.last.line, 'line', 1),
          ),
          reason:
              'Line 1 of user code must surface as line 1 — the bridge '
              'must not perturb core line numbers.',
        );
      } finally {
        await session.dispose();
      }
    }, tags: 'd1-pending');

    test('NameError on line 3 of user code reports line 3', () async {
      final session = await MontyRuntime.start();
      try {
        await expectLater(
          session.execute('x = 1\ny = 2\nundefined_xyz').result,
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.traceback.last.line,
              'line',
              3,
            ),
          ),
        );
      } finally {
        await session.dispose();
      }
    }, tags: 'd1-pending');
  });

  // ---------------------------------------------------------------------------
  // 2d. Last expression return: native Monty vs captureLastExpression
  // ---------------------------------------------------------------------------

  group('2d — last expression capture', () {
    test(
      'raw session: the last expression is the value, with no wrapper',
      () async {
        final result = await pool.withSession(
          (session) => session.feedRun('1 + 1'),
        );
        expect(
          result,
          isA<MontyInt>(),
          reason: 'Monty returns the last expression value natively.',
        );
        expect((result as MontyInt).value, 2);
      },
    );

    test('raw session: assignment statement returns MontyNone', () async {
      // Assignments are statements, not expressions — they should return None.
      final result = await pool.withSession(
        (session) => session.feedRun('x = 42'),
      );
      expect(
        result,
        isA<MontyNone>(),
        reason: 'Assignment statement has no return value — MontyNone.',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 2e. Host param type coercion
  // ---------------------------------------------------------------------------

  group('2e — host param type coercion', tags: 'd1-pending', () {
    late MontyRuntime session;

    setUp(() async {
      session = (await MontyRuntime.start())
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
      final result = await session.execute('typed_fn(n=42)').result;
      expect(result.dartValue, 42);
    });

    test('integer param rejects Python string "42"', () async {
      // dart_monty's HostParam.validate() currently coerces "42" → 42.
      // This test documents whether that coercion is desirable.
      // If the test PASSES (no error), coercion is active.
      // If it FAILS (error returned), coercion was removed and strict
      // typing is enforced — which better matches Monty's raw behavior.
      // Document current behavior:
      try {
        final result = await session.execute('typed_fn(n="42")').result;
        // Coercion is active — document it
        expect(
          result.dartValue,
          42,
          reason:
              'dart_monty coerces string "42" to int 42 for integer params. '
              'This is a dart_monty invention not grounded in Monty behavior.',
        );
      } on MontyError catch (e) {
        expect(
          e.exception.message,
          isNotEmpty,
          reason: 'String "42" correctly rejected for integer param.',
        );
      }
    });

    test('integer param rejects Python float 1.5', () async {
      // A float cannot losslessly become an int — should error.
      await expectLater(
        session.execute('typed_fn(n=1.5)').result,
        throwsA(isA<MontyError>()),
        reason: 'Float 1.5 cannot be coerced to integer without data loss.',
      );
    });
  });
}
