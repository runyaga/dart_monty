/// Tests for state persistence failure modes in AgentSession.
///
/// Three confirmed bugs and their fixes:
///
/// BUG 1 (FIXED) — Silent type coercion:
///   Non-JSON-serialisable Python values (re.Pattern, etc.) were silently
///   coerced to their string representation by the Monty bridge. After the
///   fix the Python-side isinstance filter drops them instead, and the
///   Dart-side handler logs a warning.
///
/// BUG 2 (FIXED) — No error surface:
///   execute() returned success even when values were silently coerced.
///   After the fix a warning is emitted via BridgeLogger for every dropped key.
///
/// BUG 3 (KNOWN LIMITATION + IMPROVED DIAGNOSTIC) — def functions not captured:
///   User-defined functions cannot be serialised to JSON and do not survive
///   `execute()` calls. extractAssignmentTargets now captures `def` names so
///   the Dart-side handler can warn explicitly rather than the developer seeing
///   a cryptic "Unknown function: name" error on the next call.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/state_persistence_test.dart
/// ```
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Shared mode
  // ---------------------------------------------------------------------------
  group(
    'state persistence — BUG 1 (type coercion) fixed, shared mode',
    () {
      late AgentSession session;
      late _CapturingLogger logger;

      setUp(() {
        logger = _CapturingLogger();
        session = AgentSession(logger: logger);
      });
      tearDown(() async => session.dispose());

      test(
        're.compile() is filtered (not coerced to string) across calls',
        () async {
          await session.execute(r'''
import re
pattern = re.compile(r'\d+')
''');

          // After the fix: pattern is NOT in state (filtered),
          // so accessing it raises NameError — no string coercion.
          final r = await session.execute('''
try:
    t = type(pattern).__name__
except NameError:
    t = "gone"
t
''');

          expect(r.error, isNull);
          // "gone" confirms it was filtered out, not coerced to "str".
          expect(
            r.value.dartValue,
            'gone',
            reason: 'pattern should be absent (filtered), not coerced to str',
          );
        },
      );

      test(
        'serialisable vars in same call as non-serialisable ones persist',
        () async {
          await session.execute(r'''
import re
pattern = re.compile(r'\d+')
y = 99
name = "alice"
''');

          final r = await session.execute('[y, name]');

          expect(r.error, isNull);
          expect(r.value.dartValue, [99, 'alice']);
        },
      );

      test(
        'prior state preserved when call introduces non-serialisable values',
        () async {
          await session.execute('x = 42');

          await session.execute(r'''
import re
pattern = re.compile(r'\d+')
''');

          final r = await session.execute('x');
          expect(r.value.dartValue, 42);
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  group(
    'state persistence — BUG 2 (warning surface) fixed, shared mode',
    () {
      test(
        're.compile() drop emits a logger warning with the key name',
        () async {
          final logger = _CapturingLogger();
          final session = AgentSession(logger: logger);
          addTearDown(session.dispose);

          await session.execute(r'''
import re
pattern = re.compile(r'\d+')
x = 1
''');

          expect(
            logger.warnings,
            isNotEmpty,
            reason: 'a warning must be emitted when a value is dropped',
          );
          expect(
            logger.warnings.join(' '),
            contains('pattern'),
            reason: 'warning must name the dropped key',
          );
        },
      );

      test(
        'no warning emitted when all values are serialisable',
        () async {
          final logger = _CapturingLogger();
          final session = AgentSession(logger: logger);
          addTearDown(session.dispose);

          await session.execute('x = 42\nname = "alice"\ndata = [1, 2, 3]');

          expect(
            logger.warnings,
            isEmpty,
            reason: 'no warning for fully-serialisable state',
          );
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  group(
    'state persistence — BUG 3 (def functions) known limitation + warning',
    () {
      test(
        'def function name is captured and a warning is emitted',
        () async {
          final logger = _CapturingLogger();
          final session = AgentSession(logger: logger);
          addTearDown(session.dispose);

          await session.execute('''
def double(x):
    return x * 2
''');

          expect(
            logger.warnings,
            isNotEmpty,
            reason:
                'warning must be emitted so developer knows '
                'double cannot persist',
          );
          expect(
            logger.warnings.join(' '),
            contains('double'),
            reason: 'warning must name the function that was dropped',
          );
        },
      );

      test(
        'def function works within the same execute() call',
        () async {
          final session = AgentSession();
          addTearDown(session.dispose);

          // Function defined and used in the same call — should work.
          final r = await session.execute('''
def double(x):
    return x * 2
double(21)
''');

          expect(r.error, isNull);
          expect(r.value.dartValue, 42);
        },
      );

      test(
        'def function is not available in subsequent call (known limitation)',
        () async {
          final session = AgentSession();
          addTearDown(session.dispose);

          await session.execute('''
def double(x):
    return x * 2
''');

          // Known limitation: user-defined functions cannot be serialised
          // to JSON and do not survive between execute() calls.
          final r = await session.execute('double(21)');

          expect(
            r.error,
            isNotNull,
            reason:
                'function does not persist — this is a known limitation. '
                'Define and use functions within the same execute() call, '
                'or use a host function registered via session.register().',
          );
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // Sandbox mode — same fixes apply
  // ---------------------------------------------------------------------------
  group('state persistence — fixes apply in sandbox mode', () {
    late AgentSession session;
    late _CapturingLogger logger;

    setUp(() {
      logger = _CapturingLogger();
      session = AgentSession(sandbox: true, logger: logger);
    });
    tearDown(() async => session.dispose());

    test(
      're.compile() filtered (not coerced), serialisable vars persist',
      () async {
        await session.execute(r'''
import re
pattern = re.compile(r'\d+')
x = 42
''');

        // x should persist, pattern should be absent.
        final r = await session.execute('''
import re
try:
    t = type(pattern).__name__
except NameError:
    t = "gone"
[x, t]
''');

        expect(r.error, isNull);
        expect(r.value.dartValue, [42, 'gone']);
      },
    );

    test(
      'warning emitted for non-serialisable value in sandbox mode',
      () async {
        await session.execute(r'''
import re
pattern = re.compile(r'\d+')
''');

        expect(logger.warnings, isNotEmpty);
        expect(logger.warnings.join(' '), contains('pattern'));
      },
    );

    test('warning emitted for def function in sandbox mode', () async {
      await session.execute('''
def triple(x):
    return x * 3
''');

      expect(logger.warnings, isNotEmpty);
      expect(logger.warnings.join(' '), contains('triple'));
    });

    test('serialisable state persists correctly', () async {
      await session.execute('x = 42');
      final r = await session.execute('x + 1');

      expect(r.value.dartValue, 43);
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class _CapturingLogger implements BridgeLogger {
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  void trace(String message, {Map<String, Object?>? attributes}) {}

  @override
  void debug(String message, {Map<String, Object?>? attributes}) {}

  @override
  void info(String message, {Map<String, Object?>? attributes}) {}

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    warnings.add(message);
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    errors.add(message);
  }

  @override
  BridgeLogger child(String name) => this;

  @override
  void close() {}
}
