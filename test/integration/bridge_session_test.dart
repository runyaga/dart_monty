// MontyBridge over a real worker session: run events, print collection,
// Python failures and the OS-call rules (D1-2).
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;
  late MontySession session;
  late MontyBridge bridge;

  setUpAll(() async {
    pool = await startTestPool();
  });

  tearDownAll(() async {
    await pool.close();
  });

  setUp(() async {
    session = await pool.checkout();
    bridge = MontyBridge(session: session, logger: BridgeLogger.silent);
  });

  tearDown(() async {
    bridge.dispose();
    await session.close();
  });

  test('a run collects print output and ends with its value', () async {
    final events = await bridge
        .execute('print("hello")\nprint("world")\n6 * 7')
        .toList();

    expect(events.first, isA<BridgeRunStarted>());
    final finished = events.last as BridgeRunFinished;
    expect(finished.value, 42);
    expect(finished.montyValue, const MontyInt(42));
    expect(finished.printOutput, 'hello\nworld\n');
  });

  test('a Python exception ends the run with BridgeRunError', () async {
    final events = await bridge
        .execute('print("before")\nraise ValueError("boom")')
        .toList();

    final error = events.last as BridgeRunError;
    expect(events.whereType<BridgeRunError>(), hasLength(1));
    expect(error.exception, isA<MontyRuntimeError>());
    expect(error.message, 'ValueError: boom');
    expect(error.printOutput, 'before\n');
  });

  test('a syntax error ends the run with MontySyntaxError', () async {
    final events = await bridge.execute('def (').toList();

    expect(
      events.whereType<BridgeRunError>().single.exception,
      isA<MontySyntaxError>(),
    );
  });

  test('a type-check rejection ends the run with MontyTypingError', () async {
    final checked = await pool.checkout(typeCheck: true);
    addTearDown(checked.close);
    final b = MontyBridge(session: checked, logger: BridgeLogger.silent);
    addTearDown(b.dispose);

    final events = await b.execute('x: int = "not an int"').toList();

    expect(
      events.whereType<BridgeRunError>().single.exception,
      isA<MontyTypingError>(),
    );
  });

  test('with no OS handler a filesystem call takes the worker default', () {
    return expectLater(
      _caught(bridge, "open('/nope.txt').read()"),
      completion(startsWith('PermissionError')),
    );
  });

  test('with no OS handler a non-filesystem call raises RuntimeError and '
      'emits no events', () async {
    final events = await bridge
        .execute(_tryCatch('os.getenv("HOME")'))
        .toList();

    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
    expect(events.whereType<BridgeOsCallResult>(), isEmpty);
    expect(
      (events.last as BridgeRunFinished).value,
      allOf(startsWith('RuntimeError'), contains('not supported')),
    );
  });

  test('a declining handler yields the worker default and Declined', () async {
    bridge.registerOs(
      (name, args, kwargs) => throw const OsCallNotHandledException(),
    );

    final events = await bridge
        .execute(_tryCatch("open('/nope.txt').read()"))
        .toList();

    expect(
      (events.last as BridgeRunFinished).value,
      allOf(startsWith('PermissionError'), contains('/nope.txt')),
    );
    expect(events.whereType<BridgeOsCallResult>().single.result, 'Declined');
  });

  test(
    'a declined non-filesystem call raises the worker RuntimeError',
    () async {
      bridge.registerOs(
        (name, args, kwargs) => throw const OsCallNotHandledException(),
      );

      final events = await bridge
          .execute(_tryCatch('os.getenv("HOME")'))
          .toList();

      expect(
        (events.last as BridgeRunFinished).value,
        allOf(
          startsWith('RuntimeError'),
          contains('is not supported in this environment'),
        ),
      );
      expect(events.whereType<BridgeOsCallResult>().single.result, 'Declined');
    },
  );

  test('a host handler answers and its call is reported', () async {
    bridge.registerOs((name, args, kwargs) {
      if (name == 'os.getenv') return const MontyString('from-host');
      throw const OsCallNotHandledException();
    });

    final events = await bridge
        .execute('import os\nos.getenv("APP_ENV")')
        .toList();

    expect((events.last as BridgeRunFinished).value, 'from-host');
    final start = events.whereType<BridgeOsCallStart>().single;
    expect(start.operationName, 'os.getenv');
    final result = events.whereType<BridgeOsCallResult>().single;
    expect(result.callId, start.callId);
    expect(result.result, 'from-host');
    expect(result.durationMs, isNotNull);
  });

  test('a handler ExternalException is raised as its Python type', () async {
    bridge.registerOs(
      (name, args, kwargs) =>
          throw const ExternalException('FileNotFoundError', 'gone'),
    );

    final events = await bridge
        .execute(_tryCatch("open('/x.txt').read()"))
        .toList();

    expect((events.last as BridgeRunFinished).value, 'FileNotFoundError: gone');
    expect(
      events.whereType<BridgeOsCallResult>().single.result,
      'Error: gone',
    );
  });

  test('calls the worker answers itself never reach the handler', () async {
    var reached = 0;
    bridge.registerOs((name, args, kwargs) {
      reached++;
      throw const OsCallNotHandledException();
    });

    // The default OsPolicy answers the clock and time.sleep in the worker.
    final sw = Stopwatch()..start();
    final events = await bridge
        .execute(
          'import datetime, time\n'
          'time.sleep(0.05)\n'
          'datetime.datetime.now().year > 2000',
        )
        .toList();
    sw.stop();

    expect((events.last as BridgeRunFinished).value, isTrue);
    expect(reached, 0);
    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
    // The session waited the sleep itself.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(50));
  });
}

/// [expr] run in a try block; the run's value is `'<type>: <message>'` of
/// what it raised.
String _tryCatch(String expr) =>
    '''
import os
try:
    $expr
    out = 'NO EXCEPTION RAISED'
except Exception as e:
    out = type(e).__name__ + ': ' + str(e)
out
''';

/// The `'<type>: <message>'` of what [expr] raises on [bridge].
Future<String> _caught(MontyBridge bridge, String expr) async {
  final events = await bridge.execute(_tryCatch(expr)).toList();

  return (events.last as BridgeRunFinished).value! as String;
}
