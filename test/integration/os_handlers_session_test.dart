// The OS handlers dm ships (D1-5), driven by real Python on a worker session:
// a decline stays synchronous through composition and decoration, so the
// worker's own default answers; typed failures and a None result survive the
// MontyValue boundary.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
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

  group('handler outcomes through core', () {
    test('a None answer reaches Python as None', () async {
      bridge.registerOs((name, args, kwargs) => const MontyNone());

      final out = await _run(bridge, "import os\nos.getenv('X') is None");

      expect(out, 'True');
    });

    test('keyword arguments arrive as a map', () async {
      Map<String, Object?>? seen;
      bridge.registerOs((name, args, kwargs) {
        seen = {for (final e in kwargs.entries) e.key: e.value.dartValue};

        return const MontyNone();
      });

      await _run(bridge, "Path('/d').mkdir(parents=True, exist_ok=True)");

      expect(seen, {'parents': true, 'exist_ok': true});
    });

    test('a failing Future does not decline: Python sees an error', () async {
      bridge.registerOs(
        (name, args, kwargs) async => throw const OsCallNotHandledException(),
      );

      final out = await _caught(bridge, "open('/nope.txt').read()");

      // Not the PermissionError a synchronous decline gives.
      expect(out, isNot(startsWith('PermissionError')));
      expect(out, startsWith('TypeError'));
    });

    test('an uncaught handler failure ends the run with that error', () async {
      bridge.registerOs(
        (name, args, kwargs) =>
            throw const ExternalException('FileNotFoundError', 'gone'),
      );

      final events = await bridge.execute("open('/x.txt').read()").toList();

      final [..., error] = events;
      expect((error as BridgeRunError).message, 'FileNotFoundError: gone');
    });

    test('another throw is Exception with its text', () async {
      bridge.registerOs((name, args, kwargs) => throw StateError('boom'));

      final out = await _caught(bridge, "open('/nope.txt').read()");

      expect(out, allOf(startsWith('Exception'), contains('boom')));
    });
  });
}

String _tryCatch(String expr) =>
    '''
import os
from pathlib import Path
try:
    $expr
    out = 'NO EXCEPTION RAISED'
except Exception as e:
    out = type(e).__name__ + ': ' + str(e)
out
''';

Future<String> _caught(MontyBridge bridge, String expr) async {
  final events = await bridge.execute(_tryCatch(expr)).toList();

  final [..., last] = events;
  return (last as BridgeRunFinished).value! as String;
}

/// The `repr` of the last expression of [code].
Future<String> _run(MontyBridge bridge, String code) async {
  final [...prefix, lastLine] = code.trimRight().split('\n');
  final wrapped = [...prefix, 'repr($lastLine)'].join('\n');
  final events = await bridge
      .execute('import os\nfrom pathlib import Path\n$wrapped')
      .toList();
  final [..., last] = events;
  if (last is BridgeRunError) fail('run failed: ${last.message}');

  return (last as BridgeRunFinished).value! as String;
}
