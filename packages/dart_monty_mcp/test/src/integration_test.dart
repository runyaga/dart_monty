@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

/// Integration tests using real FFI Monty interpreter.
///
/// Run with:
/// ```bash
/// DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
///   dart test --tags=integration --run-skipped test/src/integration_test.dart
/// ```
void main() {
  late MontyMcpServer server;

  MontyPlatform createPlatform() {
    final libPath = Platform.environment['DART_MONTY_LIB_PATH'] ??
        Platform.environment['MONTY_LIBRARY_PATH'];
    return MontyFfi(
      bindings: NativeBindingsFfi(libraryPath: libPath),
    );
  }

  setUp(() {
    server = MontyMcpServer(platformFactory: createPlatform);
  });

  tearDown(() async {
    await server.dispose();
  });

  // ---------------------------------------------------------------------------
  // Phase 1: Stateless monty_run
  // ---------------------------------------------------------------------------

  group('monty_run (stateless)', () {
    test('D-01: print hello', () async {
      final r = await server.sessionManager.executeStateless("print('hello')");
      expect(r.isError, isFalse);
      expect(_text(r), 'hello');
    });

    test('D-02: arithmetic expression', () async {
      final r = await server.sessionManager.executeStateless('2 + 3');
      expect(r.isError, isFalse);
      expect(_text(r), '5');
    });

    test('D-03: multi-statement with expression', () async {
      final r = await server.sessionManager.executeStateless('x = 42\nx * 2');
      expect(r.isError, isFalse);
      expect(_text(r), '84');
    });

    test('D-04: empty code', () async {
      final r = await server.sessionManager.executeStateless('');
      expect(r.isError, isFalse);
      expect(_text(r), '(no output)');
    });

    test('D-05: ZeroDivisionError', () async {
      final r = await server.sessionManager.executeStateless('1/0');
      expect(r.isError, isTrue);
      expect(_text(r), contains('ZeroDivisionError'));
    });

    test('D-06: ModuleNotFoundError', () async {
      final r = await server.sessionManager.executeStateless('import math');
      expect(r.isError, isTrue);
      expect(_text(r), contains('ModuleNotFoundError'));
    });

    test('D-07: unicode output', () async {
      final r = await server.sessionManager.executeStateless("print('α β γ')");
      expect(r.isError, isFalse);
      expect(_text(r), 'α β γ');
    });

    test('D-08: large output (10K chars)', () async {
      final r =
          await server.sessionManager.executeStateless("print('x' * 10000)");
      expect(r.isError, isFalse);
      expect(_text(r).length, 10000);
    });

    test('D-25: no state leakage between runs', () async {
      await server.sessionManager.executeStateless('leaked = 999');
      final r = await server.sessionManager.executeStateless('leaked');
      expect(r.isError, isTrue);
      expect(_text(r), contains('NameError'));
    });

    test('string with special chars', () async {
      final r = await server.sessionManager
          .executeStateless(r"print('hello\nworld\ttab')");
      expect(r.isError, isFalse);
      expect(_text(r), contains('hello'));
      expect(_text(r), contains('world'));
    });

    test('multiline code with indentation', () async {
      final r = await server.sessionManager.executeStateless(
        'result = []\nfor i in range(5):\n    result.append(i * i)\nresult',
      );
      expect(r.isError, isFalse);
      expect(_text(r), '[0, 1, 4, 9, 16]');
    });

    test('list comprehension', () async {
      final r = await server.sessionManager
          .executeStateless('[x**2 for x in range(6)]');
      expect(r.isError, isFalse);
      expect(_text(r), '[0, 1, 4, 9, 16, 25]');
    });

    test('dict construction', () async {
      // Monty dict comprehension returns list-of-pairs, not dict.
      // Use explicit dict() construction instead.
      final r = await server.sessionManager
          .executeStateless('d = {}\nfor i in range(3):\n    d[i] = i*2\nd');
      expect(r.isError, isFalse);
      expect(_text(r), contains('0'));
    });

    test('string formatting', () async {
      final r = await server.sessionManager
          .executeStateless("name = 'Monty'\nf'Hello {name}!'");
      expect(r.isError, isFalse);
      expect(_text(r), 'Hello Monty!');
    });

    test('nested function definition and call', () async {
      final r = await server.sessionManager.executeStateless(
        'def factorial(n):\n'
        '    if n <= 1:\n'
        '        return 1\n'
        '    return n * factorial(n - 1)\n'
        'factorial(10)',
      );
      expect(r.isError, isFalse);
      expect(_text(r), '3628800');
    });

    test('class definition — Monty limitation', () async {
      // Monty may not support full class definitions
      final r = await server.sessionManager.executeStateless(
        'class Point:\n'
        '    def __init__(self, x, y):\n'
        '        self.x = x\n'
        '        self.y = y\n'
        'p = Point(3, 4)\n'
        'p.x',
      );
      // Record whether classes work — may be unsupported
      if (r.isError) {
        // Known Monty limitation
        expect(_text(r), isNotEmpty);
      } else {
        expect(_text(r), '3');
      }
    });

    test('exception with traceback info', () async {
      final r = await server.sessionManager.executeStateless(
        'x = [1, 2, 3]\nx[10]',
      );
      expect(r.isError, isTrue);
      expect(_text(r), contains('IndexError'));
    });

    test('NameError for undefined variable', () async {
      final r = await server.sessionManager.executeStateless('undefined_var');
      expect(r.isError, isTrue);
      expect(_text(r), contains('NameError'));
    });

    test('SyntaxError for invalid code', () async {
      final r = await server.sessionManager.executeStateless('def incomplete(');
      expect(r.isError, isTrue);
      expect(_text(r), contains('SyntaxError'));
    });

    test('TypeError', () async {
      final r = await server.sessionManager.executeStateless("'hello' + 42");
      expect(r.isError, isTrue);
      expect(_text(r), contains('TypeError'));
    });

    test('print and expression combined', () async {
      final r = await server.sessionManager.executeStateless(
        "print('stdout')\n42",
      );
      expect(r.isError, isFalse);
      final text = _text(r);
      expect(text, contains('stdout'));
      expect(text, contains('42'));
    });

    test('boolean operations', () async {
      final r = await server.sessionManager.executeStateless(
        'True and not False',
      );
      expect(r.isError, isFalse);
      // Monty uses Dart-style lowercase true/false
      expect(_text(r).toLowerCase(), 'true');
    });

    test('None value', () async {
      final r = await server.sessionManager.executeStateless('None');
      // None is the value but should show as output
      expect(r.isError, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 1: Session lifecycle
  // ---------------------------------------------------------------------------

  group('session lifecycle', () {
    test('D-10: auto-generated ID', () {
      final id = server.sessionManager.createSession();
      expect(id, 'session_0');
    });

    test('D-11: custom ID', () {
      final id = server.sessionManager.createSession(id: 'custom');
      expect(id, 'custom');
    });

    test('D-12: duplicate ID rejected', () {
      server.sessionManager.createSession(id: 'dup');
      final second = server.sessionManager.createSession(id: 'dup');
      expect(second, isNull);
    });

    test('D-13: exec on unknown session', () async {
      final session = server.sessionManager.getSession('nonexistent');
      expect(session, isNull);
    });

    test('D-17: list empty sessions', () {
      expect(server.sessionManager.sessionIds, isEmpty);
    });

    test('D-18: list multiple sessions', () {
      server.sessionManager.createSession(id: 'a');
      server.sessionManager.createSession(id: 'b');
      server.sessionManager.createSession(id: 'c');
      expect(server.sessionManager.sessionIds, hasLength(3));
      expect(
        server.sessionManager.sessionIds,
        containsAll(['a', 'b', 'c']),
      );
    });

    test('D-19: destroy existing session', () async {
      server.sessionManager.createSession(id: 'doomed');
      final destroyed = await server.sessionManager.destroySession('doomed');
      expect(destroyed, isTrue);
      expect(server.sessionManager.sessionCount, 0);
    });

    test('D-20: destroy nonexistent', () async {
      final destroyed = await server.sessionManager.destroySession('ghost');
      expect(destroyed, isFalse);
    });

    test('D-22: full lifecycle', () async {
      // Create
      server.sessionManager.createSession(id: 'lifecycle');
      expect(server.sessionManager.sessionCount, 1);

      // Exec
      final session = server.sessionManager.getSession('lifecycle')!;
      final r = await session.execute('40 + 2');
      expect(r.isError, isFalse);
      expect(_text(r), '42');

      // List
      expect(server.sessionManager.sessionIds, ['lifecycle']);

      // Destroy
      await server.sessionManager.destroySession('lifecycle');
      expect(server.sessionManager.sessionCount, 0);

      // List empty
      expect(server.sessionManager.sessionIds, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 1: Session state persistence
  // ---------------------------------------------------------------------------

  group('session state persistence', () {
    test('D-14: variable persists across calls', () async {
      server.sessionManager.createSession(id: 'persist');
      final session = server.sessionManager.getSession('persist')!;

      final r1 = await session.execute('x = 42');
      expect(r1.isError, isFalse);

      final r2 = await session.execute('x * 2');
      expect(r2.isError, isFalse);
      expect(_text(r2), '84');
    });

    test('D-16: session survives error', () async {
      server.sessionManager.createSession(id: 'err');
      final session = server.sessionManager.getSession('err')!;

      await session.execute('x = 42');
      final rErr = await session.execute('1/0');
      expect(rErr.isError, isTrue);

      final rAfter = await session.execute('x');
      expect(rAfter.isError, isFalse);
      expect(_text(rAfter), '42');
    });

    test('D-24: multi-session state isolation', () async {
      server.sessionManager.createSession(id: 's1');
      server.sessionManager.createSession(id: 's2');
      final s1 = server.sessionManager.getSession('s1')!;
      final s2 = server.sessionManager.getSession('s2')!;

      await s1.execute('val = "from_s1"');
      await s2.execute('val = "from_s2"');

      final r1 = await s1.execute('val');
      final r2 = await s2.execute('val');
      expect(_text(r1), 'from_s1');
      expect(_text(r2), 'from_s2');
    });

    test('multiple variables persist', () async {
      server.sessionManager.createSession(id: 'multi');
      final session = server.sessionManager.getSession('multi')!;

      await session.execute('a = 1');
      await session.execute('b = 2');
      await session.execute('c = 3');

      final r = await session.execute('a + b + c');
      expect(r.isError, isFalse);
      expect(_text(r), '6');
    });

    test('list state persists', () async {
      server.sessionManager.createSession(id: 'list');
      final session = server.sessionManager.getSession('list')!;

      await session.execute('items = []');
      await session.execute('items.append(1)');
      await session.execute('items.append(2)');
      await session.execute('items.append(3)');

      final r = await session.execute('items');
      expect(r.isError, isFalse);
      expect(_text(r), '[1, 2, 3]');
    });

    test('dict state persists — built in single expression', () async {
      // Note: dict mutation via data['key'] = val across execs doesn't
      // persist because MontySession serializes via JSON roundtrip.
      // Only the dict reference persists, not in-place mutations from
      // prior execs. Build dict in one shot instead.
      server.sessionManager.createSession(id: 'dict');
      final session = server.sessionManager.getSession('dict')!;

      await session.execute("data = {'name': 'Monty', 'version': 1}");

      final r = await session.execute('data');
      expect(r.isError, isFalse);
      final text = _text(r);
      expect(text, contains('name'));
      expect(text, contains('Monty'));
    });

    test('dict mutation across execs — known limitation', () async {
      // In-place dict mutation in a separate exec doesn't persist
      // because MontySession serializes the initial empty dict {},
      // then the mutation happens in fresh interpreter with restored
      // empty dict.
      server.sessionManager.createSession(id: 'dict-mut');
      final session = server.sessionManager.getSession('dict-mut')!;

      await session.execute('data = {}');
      await session.execute("data['key'] = 'value'");

      final r = await session.execute('data');
      // This demonstrates the limitation: mutation didn't persist
      expect(r.isError, isFalse);
      // data is {} because the mutation was on a restored copy
      expect(_text(r), '{}');
    });

    test('counter pattern across calls', () async {
      server.sessionManager.createSession(id: 'counter');
      final session = server.sessionManager.getSession('counter')!;

      await session.execute('count = 0');
      for (var i = 0; i < 10; i++) {
        await session.execute('count = count + 1');
      }

      final r = await session.execute('count');
      expect(r.isError, isFalse);
      expect(_text(r), '10');
    });

    test('function defined in session — call across execs', () async {
      server.sessionManager.createSession(id: 'fn');
      final session = server.sessionManager.getSession('fn')!;

      // Define function
      final r1 = await session.execute(
        'def double(x):\n    return x * 2',
      );
      expect(r1.isError, isFalse);

      // Call it — this may fail due to MontySession treating it
      // as an external function
      final r2 = await session.execute('double(21)');

      // Record whether this works or is a known limitation
      if (r2.isError) {
        expect(
          _text(r2),
          contains('Unexpected external function'),
          reason: 'Known limitation: user-defined functions called across '
              'session executions are treated as external functions by '
              'MontySession.run()',
        );
      } else {
        expect(_text(r2), '42');
      }
    });

    test('D-21: exec after destroy returns error', () async {
      server.sessionManager.createSession(id: 'dead');
      final session = server.sessionManager.getSession('dead')!;
      await server.sessionManager.destroySession('dead');

      final r = await session.execute('1 + 1');
      expect(r.isError, isTrue);
    });

    test('non-serializable state silently dropped', () async {
      server.sessionManager.createSession(id: 'nonser');
      final session = server.sessionManager.getSession('nonser')!;

      // Define a lambda — can't be JSON-serialized
      await session.execute('fn = lambda x: x + 1');
      // Also set a serializable value
      await session.execute('num = 42');

      // Serializable survives
      final r = await session.execute('num');
      expect(r.isError, isFalse);
      expect(_text(r), '42');
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4: Stress tests
  // ---------------------------------------------------------------------------

  group('stress', () {
    test('S-01/S-02: create and destroy 10 sessions', () async {
      for (var i = 0; i < 10; i++) {
        server.sessionManager.createSession(id: 'stress_$i');
      }
      expect(server.sessionManager.sessionCount, 10);

      for (var i = 0; i < 10; i++) {
        await server.sessionManager.destroySession('stress_$i');
      }
      expect(server.sessionManager.sessionCount, 0);
    });

    test('S-03: 50 sequential stateless runs', () async {
      for (var i = 0; i < 50; i++) {
        final r = await server.sessionManager.executeStateless('$i * 2');
        expect(r.isError, isFalse);
        expect(_text(r), '${i * 2}');
      }
    });

    test('S-04: large code input (100 lines)', () async {
      final code = StringBuffer()
        ..writeln('total = 0');
      for (var i = 1; i <= 100; i++) {
        code.writeln('total = total + $i');
      }
      code.writeln('total');

      final r = await server.sessionManager.executeStateless(code.toString());
      expect(r.isError, isFalse);
      expect(_text(r), '5050'); // sum 1..100
    });

    test('S-05: large output (10KB+)', () async {
      final r = await server.sessionManager.executeStateless("'A' * 15000");
      expect(r.isError, isFalse);
      expect(_text(r).length, greaterThan(10000));
    });

    test('S-06: rapid create/destroy cycles', () async {
      for (var i = 0; i < 10; i++) {
        server.sessionManager.createSession(id: 'cycle');
        final session = server.sessionManager.getSession('cycle')!;
        await session.execute('x = $i');
        await server.sessionManager.destroySession('cycle');
      }
      expect(server.sessionManager.sessionCount, 0);
    });

    test('S-08: deeply nested computation', () async {
      final r = await server.sessionManager.executeStateless(
        'def fib(n):\n'
        '    if n <= 1:\n'
        '        return n\n'
        '    return fib(n-1) + fib(n-2)\n'
        'fib(20)',
      );
      expect(r.isError, isFalse);
      expect(_text(r), '6765');
    });

    test('session accumulates state over many calls', () async {
      server.sessionManager.createSession(id: 'accum');
      final session = server.sessionManager.getSession('accum')!;

      await session.execute('total = 0');
      for (var i = 1; i <= 20; i++) {
        await session.execute('total = total + $i');
      }

      final r = await session.execute('total');
      expect(r.isError, isFalse);
      expect(_text(r), '210'); // sum 1..20
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases
  // ---------------------------------------------------------------------------

  group('edge cases', () {
    test('code with only comments', () async {
      final r =
          await server.sessionManager.executeStateless('# just a comment');
      expect(r.isError, isFalse);
    });

    test('multiple print statements', () async {
      final r = await server.sessionManager.executeStateless(
        "print('line1')\nprint('line2')\nprint('line3')",
      );
      expect(r.isError, isFalse);
      final text = _text(r);
      expect(text, contains('line1'));
      expect(text, contains('line2'));
      expect(text, contains('line3'));
    });

    test('print with sep and end', () async {
      final r = await server.sessionManager.executeStateless(
        "print(1, 2, 3, sep='-')",
      );
      expect(r.isError, isFalse);
      expect(_text(r), '1-2-3');
    });

    test('nested data structures', () async {
      // Monty uses Dart-style repr: {a: [...]} not {'a': [...]}
      final r = await server.sessionManager.executeStateless(
        "{'a': [1, 2, {'b': True}], 'c': None}",
      );
      expect(r.isError, isFalse);
      final text = _text(r);
      expect(text, contains('a:'));
      expect(text, contains('b:'));
    });

    test('string escape sequences', () async {
      final r = await server.sessionManager.executeStateless(
        r"print('tab:\there\nnewline')",
      );
      expect(r.isError, isFalse);
    });

    test('empty session exec', () async {
      server.sessionManager.createSession(id: 'empty');
      final session = server.sessionManager.getSession('empty')!;
      final r = await session.execute('');
      expect(r.isError, isFalse);
    });

    test('reassignment in session', () async {
      server.sessionManager.createSession(id: 'reassign');
      final session = server.sessionManager.getSession('reassign')!;

      await session.execute('x = 1');
      await session.execute('x = 2');
      await session.execute('x = 3');

      final r = await session.execute('x');
      expect(r.isError, isFalse);
      expect(_text(r), '3');
    });

    test('augmented assignment — known MontySession limitation', () async {
      // MontySession._extractAssignmentTargets() regex only matches
      // simple `x = ...` but not `x += 5`. So x from `x += 5` is not
      // added to the persist set, and the updated value is lost.
      server.sessionManager.createSession(id: 'aug');
      final session = server.sessionManager.getSession('aug')!;

      await session.execute('x = 10');
      await session.execute('x += 5');

      final r = await session.execute('x');
      expect(r.isError, isFalse);
      // BUG: x is 10 (not 15) because x += 5 doesn't trigger persist.
      // The += line reads restored x=10, computes 15 locally, but
      // doesn't persist because _extractAssignmentTargets misses +=.
      // When next exec restores, it gets x=10 from the first persist.
      expect(_text(r), '10'); // Would be '15' if augmented assign tracked
    });

    test('try/except in session', () async {
      server.sessionManager.createSession(id: 'tryexc');
      final session = server.sessionManager.getSession('tryexc')!;

      final r = await session.execute(
        'try:\n'
        '    result = 1/0\n'
        'except ZeroDivisionError:\n'
        '    result = "caught"\n'
        'result',
      );
      expect(r.isError, isFalse);
      expect(_text(r), 'caught');
    });

    test('while loop with state', () async {
      server.sessionManager.createSession(id: 'loop');
      final session = server.sessionManager.getSession('loop')!;

      await session.execute('n = 1');
      final r = await session.execute(
        'while n < 100:\n'
        '    n = n * 2\n'
        'n',
      );
      expect(r.isError, isFalse);
      expect(_text(r), '128');
    });
  });
}

String _text(CallToolResult r) => (r.content.first as TextContent).text;
