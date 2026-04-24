// Experiment: fault injection through the harness interceptor.
//
// Exercises what happens when host functions fail, return unexpected types,
// are slow, or are denied. Python must handle these correctly — or reveal
// that it can't. No server required.
//
// Run with:
//   dart test --tags=integration --run-skipped \
//     test/experiment/examples/fault_injection_experiment_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Fault: tool throws — Python sees error, session survives
  // ---------------------------------------------------------------------------

  group('ToolFault.throws — Python error containment', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool('risky_op', (args, ctx) async => 'success');
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('injected throw surfaces as Python error, session survives', () async {
      h.injectFault('risky_op', ToolFault.throws(Exception('db_timeout')));

      final r = await h.run('risky_op()');
      expect(
        r.error,
        isNotNull,
        reason: 'Injected throw must surface as a Python-level error',
      );

      // Session must survive — clear the fault and retry.
      h.clearFault('risky_op');
      final r2 = await h.run('risky_op()');
      expect(r2.error, isNull);
      expect(r2.value.dartValue, 'success');
    });

    test('Python try/except catches injected error', () async {
      h.injectFault('risky_op', ToolFault.throws(Exception('transient')));

      final r = await h.run('''
try:
    result = risky_op()
except Exception as e:
    result = f'caught:{str(e)}'
result
''');

      expect(
        r.error,
        isNull,
        reason: 'Python try/except should handle the injected error',
      );
      expect(r.value.dartValue.toString(), contains('caught'));
    });

    test('error in one tool does not block unrelated tools', () async {
      h
        ..registerTool('stable_op', (args, ctx) async => 42)
        ..injectFault('risky_op', ToolFault.throws(Exception('boom')));

      await h.run('risky_op()'); // error — recorded

      final r = await h.run('stable_op()');
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);

      h
        ..assertCalled('risky_op')
        ..assertCalled('stable_op');
    });
  });

  // ---------------------------------------------------------------------------
  // Fault: tool returns overridden value
  // ---------------------------------------------------------------------------

  group('ToolFault.returns — result override', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'fetch_price',
          (args, ctx) async => {'price': 99.99, 'currency': 'USD'},
          params: [
            const HostParam(name: 'symbol', type: HostParamType.string),
          ],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('injected return value replaces real handler', () async {
      h.injectFault(
        'fetch_price',
        ToolFault.returns({'price': 0.01, 'currency': 'USD'}),
      );

      final r = await h.run("fetch_price(symbol='AAPL')['price']");
      expect(r.error, isNull);
      expect(r.value.dartValue, 0.01);

      h.assertCalled('fetch_price', args: {'symbol': 'AAPL'});
    });

    test('null override — Python sees None', () async {
      h.injectFault('fetch_price', ToolFault.returns(null));

      final r = await h.run('''
p = fetch_price(symbol='X')
p is None
''');
      expect(r.value.dartValue, true);
    });

    test('clear fault — real handler runs again', () async {
      h.injectFault('fetch_price', ToolFault.returns({'price': 0.01}));
      await h.run("fetch_price(symbol='X')");

      h.clearFault('fetch_price');
      final r = await h.run("fetch_price(symbol='X')['price']");
      expect(r.value.dartValue, 99.99);
    });
  });

  // ---------------------------------------------------------------------------
  // Fault: delayed tool — Python blocks, but completes
  // ---------------------------------------------------------------------------

  group('ToolFault.delayed — slow tool', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool('slow_api', (args, ctx) async => 'response');
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('delayed tool still completes — session not corrupted', () async {
      h.injectFault(
        'slow_api',
        ToolFault.delayed(
          const Duration(milliseconds: 100),
          then: 'delayed_ok',
        ),
      );

      final sw = Stopwatch()..start();
      final r = await h.run('slow_api()');
      sw.stop();

      expect(r.error, isNull);
      expect(r.value.dartValue, 'delayed_ok');
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(100));
    });
  });

  // ---------------------------------------------------------------------------
  // Systematic fault matrix: all faults on every tool in a chain
  // ---------------------------------------------------------------------------

  group('fault matrix — chain of tools under fault', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool('step_a', (args, ctx) async => 'a_ok')
        ..registerTool('step_b', (args, ctx) async => 'b_ok')
        ..registerTool('step_c', (args, ctx) async => 'c_ok');
      await h.setup();
    });

    tearDown(() => h.dispose());

    const chain = '''
a = step_a()
b = step_b()
c = step_c()
[a, b, c]
''';

    test('no faults — chain succeeds end to end', () async {
      final r = await h.run(chain);
      expect(r.error, isNull);
      expect(r.value.dartValue, ['a_ok', 'b_ok', 'c_ok']);
    });

    test('fault on step_a — step_b and step_c still called', () async {
      h.injectFault('step_a', ToolFault.returns('a_override'));

      final r = await h.run(chain);
      expect(r.error, isNull);
      expect(r.value.dartValue, ['a_override', 'b_ok', 'c_ok']);
      h
        ..assertCallCount('step_a', 1)
        ..assertCallCount('step_b', 1)
        ..assertCallCount('step_c', 1);
    });

    test('throw on step_b — step_c is NOT called (error propagates)', () async {
      h.injectFault('step_b', ToolFault.throws(Exception('b_fail')));

      final r = await h.run(chain);
      expect(
        r.error,
        isNotNull,
        reason: 'Uncaught tool error must propagate to Python',
      );
      h
        ..assertCalled('step_a')
        ..assertCalled('step_b')
        // step_c is never reached because step_b's exception propagates.
        ..assertNotCalled('step_c');
    });

    test('throw on step_b caught in Python — step_c still runs', () async {
      h.injectFault('step_b', ToolFault.throws(Exception('b_fail')));

      final r = await h.run('''
a = step_a()
try:
    b = step_b()
except Exception:
    b = 'b_fallback'
c = step_c()
[a, b, c]
''');

      expect(r.error, isNull);
      expect(r.value.dartValue, ['a_ok', 'b_fallback', 'c_ok']);
      h
        ..assertCalled('step_a')
        ..assertCalled('step_b')
        ..assertCalled('step_c');
    });
  });

  // ---------------------------------------------------------------------------
  // Call recording verification
  // ---------------------------------------------------------------------------

  group('call recording', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'log_event',
          (args, ctx) async => null,
          params: [
            const HostParam(name: 'event', type: HostParamType.string),
            const HostParam(
              name: 'seq',
              type: HostParamType.integer,
              isRequired: false,
            ),
          ],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('calls are recorded in order', () async {
      await h.run('''
log_event(event='start', seq=0)
log_event(event='middle', seq=1)
log_event(event='end', seq=2)
''');

      final calls = h.callsTo('log_event');
      expect(calls, hasLength(3));
      expect(calls[0].args['seq'], 0);
      expect(calls[1].args['seq'], 1);
      expect(calls[2].args['seq'], 2);
    });

    test('resetCalls() clears between sub-experiments', () async {
      await h.run("log_event(event='first')");
      h
        ..assertCallCount('log_event', 1)
        ..resetCalls()
        ..assertNotCalled('log_event');

      await h.run("log_event(event='second')");
      h.assertCallCount('log_event', 1);
    });

    test('succeeded calls have no error', () async {
      await h.run("log_event(event='ok')");
      final calls = h.callsTo('log_event');
      expect(calls.first.succeeded, isTrue);
      expect(calls.first.result, isNull);
    });

    test('failed calls have error recorded', () async {
      h.injectFault('log_event', ToolFault.throws(Exception('boom')));
      await h.run("log_event(event='fail')");

      final calls = h.callsTo('log_event');
      expect(calls.first.succeeded, isFalse);
      expect(calls.first.error, isNotNull);
    });

    test('assertNoErrors passes when all calls succeeded', () async {
      await h.run("log_event(event='a')");
      h.assertNoErrors();
    });
  });
}
