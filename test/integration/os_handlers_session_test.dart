// The OS handlers dm ships (D1-5), driven by real Python on a worker session:
// a decline stays synchronous through composition and decoration, so the
// worker's own default answers; typed failures and a None result survive the
// MontyValue boundary.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:file/memory.dart';
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

  group('defaultOsHandler()', () {
    test('Path and os calls are answered from the host', () async {
      final dir = Directory.systemTemp.createTempSync('d15_session_');
      addTearDown(() => dir.deleteSync(recursive: true));
      bridge.registerOs(defaultOsHandler());

      final out = await _run(bridge, '''
from pathlib import Path
import os
p = Path('${dir.path}/n.txt')
p.write_text('hi')
(p.read_text(), p.exists(), os.getenv('D15_UNSET_VAR'))
''');

      expect(out, "('hi', True, None)");
      expect(File('${dir.path}/n.txt').readAsStringSync(), 'hi');
    });

    test('a host failure is the CPython exception', () async {
      bridge.registerOs(defaultOsHandler());

      final out = await _caught(
        bridge,
        "open('${Directory.systemTemp.path}/d15_missing/x.txt').read()",
      );

      expect(out, startsWith('FileNotFoundError'));
    });

    test('an operation it does not answer takes the worker default', () async {
      bridge.registerOs(defaultOsHandler());

      final out = await _caught(bridge, "Path('/tmp').stat()");

      expect(out, startsWith('PermissionError'));
    });

    test('os.environ is answered from the host', () async {
      bridge.registerOs(defaultOsHandler());

      final out = await _caught(bridge, 'os.environ["D15_UNSET_VAR"]');

      // Answered by the handler, so the key is simply missing.
      expect(out, startsWith('KeyError'));
    });

    test("the clock is the worker's, not a handler call", () async {
      bridge.registerOs(defaultOsHandler());

      final events = await bridge
          .execute('import datetime\ndatetime.datetime.now().year > 2000')
          .toList();

      expect((events.last as BridgeRunFinished).value, isTrue);
      expect(events.whereType<BridgeOsCallStart>(), isEmpty);
    });
  });

  group('a decorated handler', () {
    test(
      'an overlay over a read-only base keeps declines and takes writes',
      () async {
        final base = fsHandler(MemoryFileSystem()..file('/a.txt').createSync());
        bridge.registerOs(
          base.readOnly().overlayWith(fsHandler(MemoryFileSystem())),
        );

        expect(
          await _caught(bridge, "Path('/a.txt').stat()"),
          startsWith('PermissionError'),
        );
        // Writes land in the scratch layer; the read-only base is untouched.
        expect(
          await _run(
            bridge,
            "Path('/a.txt').write_text('x')\nPath('/a.txt').read_text()",
          ),
          "'x'",
        );
      },
    );

    test('a decline inside an overlay layer is the worker default', () async {
      bridge.registerOs(
        overlayFsHandler(
          base: (name, args, kwargs) => throw const OsCallNotHandledException(),
          scratch: (name, args, kwargs) =>
              throw const OsCallNotHandledException(),
        ),
      );

      final events = await bridge
          .execute(_tryCatch("Path('/a.txt').read_text()"))
          .toList();

      expect(
        (events.last as BridgeRunFinished).value,
        allOf(startsWith('PermissionError'), contains('/a.txt')),
      );
      expect(events.whereType<BridgeOsCallResult>().single.result, 'Declined');
    });

    test('a sandboxed handler keeps its typed refusals', () async {
      final root = Directory.systemTemp.createTempSync('d15_sandbox_');
      addTearDown(() => root.deleteSync(recursive: true));
      bridge.registerOs(sandboxedFsHandler(root: root));

      expect(
        await _caught(bridge, "Path('/etc/hosts').read_text()"),
        startsWith('PermissionError'),
      );
      expect(
        await _caught(bridge, "Path('x').stat()"),
        startsWith('PermissionError'),
      );
    });
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

      final error = events.last as BridgeRunError;
      expect(error.message, 'FileNotFoundError: gone');
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

  return (events.last as BridgeRunFinished).value! as String;
}

/// The `repr` of the last expression of [code].
Future<String> _run(MontyBridge bridge, String code) async {
  final lines = code.trimRight().split('\n');
  lines.last = 'repr(${lines.last})';
  final events = await bridge
      .execute('import os\nfrom pathlib import Path\n${lines.join('\n')}')
      .toList();
  final last = events.last;
  if (last is BridgeRunError) fail('run failed: ${last.message}');

  return (last as BridgeRunFinished).value! as String;
}
