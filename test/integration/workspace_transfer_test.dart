@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_harness.dart';
import '_workspace_overlay_web.dart'
    if (dart.library.io) '_workspace_overlay_io.dart';

void main() {
  final h = WorkspaceHarness()..install();
  late WorkspaceTransfers transfers;
  late OSAccess parent;
  setUp(() {
    transfers = WorkspaceTransfers();
    parent = OSAccess(files: [MemoryFile('/parent/in', 'source')]);
  });
  test('an empty workspace can be created', () async {
    final w = await transfers.copyIn();
    addTearDown(w.dispose);
    final bridge = SessionBridge(session: h.session)..registerOs(w.call);
    addTearDown(bridge.dispose);
    final events = await bridge
        .executeWith(
          'import os\nfrom pathlib import Path\n'
          "(os.getcwd(), Path('.').is_dir())",
          cwd: '/work',
        )
        .toList();
    expect((events.last as BridgeRunFinished).value, ['/work', true]);
  });
  for (final readOnly in [false, true]) {
    for (final destination in ['.', './', './.', 'a/..']) {
      test(
        'a file cannot replace the root via $destination readOnly=$readOnly',
        () async {
          final calls = <String>[];
          final mapping = {destination: '/parent/in'};
          await expectLater(
            transfers.copyIn(
              parent: (name, args, kwargs) {
                calls.add(name);

                return parent.call(name, args, kwargs);
              },
              files: readOnly ? {} : mapping,
              roFiles: readOnly ? mapping : {},
            ),
            throwsA(isA<ExternalException>()),
          );
          expect(
            calls,
            everyElement(
              isIn(['Path.is_symlink', 'Path.stat', 'Path.read_bytes']),
            ),
          );
          expect(
            (await parent.call('Path.read_text', [
              MontyPath('/parent/in'),
            ], {})).dartValue,
            'source',
          );
        },
      );
    }
    for (final destination in ['.', './', './.']) {
      test(
        'a directory cannot replace the root via $destination ro=$readOnly',
        () async {
          final mapping = {destination: '/parent'};
          final w = await transfers.copyIn(
            parent: parent.call,
            files: readOnly ? {} : mapping,
            roFiles: readOnly ? mapping : {},
          );
          addTearDown(w.dispose);
          expect(
            await h.run(w, "(Path('.').is_dir(), Path('in').read_text())"),
            [true, 'source'],
          );
        },
      );
    }
  }
  test('transfers use their captured parent context', () async {
    final w = await transfers.copyIn(
      parent: parent.call,
      files: {'in': '/parent/in'},
    );
    addTearDown(w.dispose);
    final original = parent;
    parent = OSAccess(files: [MemoryFile('/parent/in', 'new context')]);
    await h.run(w, "Path('in').write_text('child')");
    await transfers.collect(w, {'in': '/parent/out'});
    expect(
      (await original.call('Path.read_text', [
        MontyPath('/parent/out'),
      ], {})).dartValue,
      'child',
    );
    expect(
      (await parent.call('Path.exists', [
        MontyPath('/parent/out'),
      ], {})).dartValue,
      false,
    );
  });
  test('transfers reject a missing adapter', () async {
    await expectLater(
      transfers.copyIn(files: {'in': '/parent/in'}),
      throwsA(isA<ExternalException>()),
    );
    final w = await transfers.copyIn();
    addTearDown(w.dispose);
    await h.run(w, "Path('out').write_text('x')");
    await expectLater(
      transfers.collect(w, {'out': '/parent/out'}),
      throwsA(isA<ExternalException>()),
    );
  });
  test('transfers preserve protected rename behavior', () async {
    final w = await transfers.copyIn(
      parent: parent.call,
      roFiles: {'d/in': '/parent/in'},
    );
    addTearDown(w.dispose);
    for (final code in [
      "Path('d').rename('moved')",
      "Path('d/in').rename('moved')",
      "Path('x').rename('d/in')",
    ]) {
      expect(
        await h.caught(w, code),
        startsWith('PermissionError: [Errno 30]'),
      );
    }
    expect(await h.run(w, "Path('d/in').read_text()"), 'source');
  });
  test('a staging failure preserves transfer accounting', () async {
    final w = await transfers.copyIn(parent: parent.call);
    addTearDown(w.dispose);
    await h.run(w, "Path('a').write_text('ok')");
    await expectLater(
      transfers.collect(w, {'a': '/parent/a', 'missing': '/parent/b'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await parent.call('Path.exists', [
        MontyPath('/parent/a'),
      ], {})).dartValue,
      false,
    );
    expect(w.writeBytes, 2);
  });
  test('collection retries after a failed transfer', () async {
    var reject = true;
    final w = await transfers.copyIn(
      parent: (name, args, kwargs) {
        if (reject &&
            name == 'Path.write_bytes' &&
            args.first.dartValue == '/parent/b') {
          throw const ExternalException('OSError', 'destination unavailable');
        }
        return parent.call(name, args, kwargs);
      },
    );
    addTearDown(w.dispose);
    await h.run(
      w,
      "Path('a').write_text('one')\nPath('b').write_text('two')\n"
      "Path('a').rename('renamed')",
    );
    const selection = {'renamed': '/parent/a', 'b': '/parent/b'};
    await expectLater(
      transfers.collect(w, selection),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await parent.call('Path.read_text', [
        MontyPath('/parent/a'),
      ], {})).dartValue,
      'one',
    );
    reject = false;
    await transfers.collect(w, selection);
    await transfers.collect(w, selection);
    expect(
      (await parent.call('Path.read_text', [
        MontyPath('/parent/b'),
      ], {})).dartValue,
      'two',
    );
  });
  test('T1-absolute-cwd', () async {
    final bridge = SessionBridge(session: h.session)..registerOs(parent.call);
    addTearDown(bridge.dispose);
    Workspace? captured;
    bridge
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'copy_inputs'),
          handler: (_, ctx) async {
            final w = captured = await transfers.copyIn(
              parent: ctx.os,
              files: {'in': '/parent/in'},
            );
            addTearDown(w.dispose);
            await h.pool.withSession(
              (child) => child.feedRun(
                'from pathlib import Path\n'
                "Path('in').write_text('independent')",
                cwd: '/work',
                os: w.call,
              ),
            );
            return const MontyNone();
          },
        ),
      )
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'collect_output'),
          handler: (_, _) async {
            await transfers.collect(captured!, {'in': '/parent/out'});
            return const MontyNone();
          },
        ),
      );
    final events = await bridge.execute("""
import os
from pathlib import Path
os.chdir('/parent')
copy_inputs()
os.chdir('/')
collect_output()
(Path('/parent/in').read_text(), Path('/parent/out').read_text())
""").toList();
    expect((events.last as BridgeRunFinished).value, ['source', 'independent']);
    await expectLater(
      transfers.copyIn(parent: parent.call, files: {'in': 'parent/in'}),
      throwsA(isA<ExternalException>()),
    );
    await expectLater(
      transfers.collect(captured!, {'in': 'relative'}),
      throwsA(isA<ExternalException>()),
    );
  });
  test('T2-overlay-rejection', () async {
    await checkNativeOverlayRejection(h, transfers);
    // A mount-only parent has no captured live callback. Sharing a fresh
    // mount table is deliberately not an adapter. D4b owns native adapters.
    final overlay = OSAccess(files: [MemoryFile('/overlay/only', 'live')]);
    await h.session.feedRun(
      'from pathlib import Path\n'
      "Path('/overlay/only').write_text('suspended state')",
      os: overlay.call,
    );
    await expectLater(
      transfers.copyIn(files: {'in': '/overlay/only'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await overlay.call('Path.read_text', [
        MontyPath('/overlay/only'),
      ], {})).dartValue,
      'suspended state',
    );
  });
  test('T4-live-osaccess', () async {
    final w = await transfers.copyIn(
      parent: parent.call,
      files: {'in': '/parent/in'},
    );
    addTearDown(w.dispose);
    await h.run(w, "Path('in').write_text('result')");
    final bridge = SessionBridge(session: h.session)..registerOs(parent.call);
    addTearDown(bridge.dispose);
    bridge.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'collect_live'),
        handler: (_, _) async {
          await transfers.collect(w, {'in': '/parent/out'});
          return const MontyNone();
        },
      ),
    );
    final events = await bridge
        .execute(
          "collect_live()\nPath('/parent/out').read_text()",
        )
        .toList();
    expect((events.last as BridgeRunFinished).value, 'result');
  });
  test('T5-dispose-order', () async {
    final admitted = Completer<void>();
    final release = Completer<void>();
    final w = await transfers.copyIn(
      parent: (name, args, kwargs) async {
        if (name == 'Path.write_bytes') {
          admitted.complete();
          await release.future;
        }
        return parent.call(name, args, kwargs);
      },
    );
    await h.run(w, "Path('a').write_text('x')");
    final collecting = transfers.collect(w, {'a': '/parent/a'});
    await admitted.future;
    var disposed = false;
    final disposing = w.dispose().then((_) {
      disposed = true;
    });
    await Future<void>.delayed(Duration.zero);
    try {
      expect(disposed, false);
    } finally {
      release.complete();
    }
    await collecting;
    await disposing;
    expect(w.memoryUsage, 0);
    await expectLater(
      transfers.collect(w, {'a': '/parent/b'}),
      throwsStateError,
    );
    expect(
      (await parent.call('Path.exists', [
        MontyPath('/parent/b'),
      ], {})).dartValue,
      false,
    );
  });
  final invalid = {
    'negative-write-cap': 'write_bytes_limit=-1',
    'increased-write-cap': 'write_bytes_limit=8388609',
    'negative-memory-cap': 'memory_usage_limit=-1',
    'increased-memory-cap': 'memory_usage_limit=8388609',
    'relative-parent': "files={'a': 'parent/in'}",
    'absolute-child': "files={'/a': '/parent/in'}",
    'escaping-child': "files={'../a': '/parent/in'}",
    'conflicting-inputs':
        "files={'d': '/parent/in'}, ro_files={'d/a': '/parent/in'}",
    'non-string-path': "files={'a': 42}",
    for (final parameter in ['files', 'ro_files'])
      for (final destination in ['.', './', './.', 'a/..'])
        'root-file-$parameter-$destination':
            "$parameter={'$destination': '/parent/in'}",
  };
  for (final entry in invalid.entries) {
    test('transfer schema rejects ${entry.key}', () async {
      final runtime = await MontyRuntime.start(
        pool: h.pool,
        os: parent.call,
        extensions: [SandboxExtension()],
      );
      addTearDown(runtime.dispose);
      await expectLater(
        runtime.execute("sandbox_spawn('1', ${entry.value})").result,
        throwsA(
          isA<MontyError>().having(
            (e) => e.toString(),
            'pre-checkout failure',
            isNot(contains('D1-8')),
          ),
        ),
      );
      expect(
        (await parent.call('Path.read_text', [
          MontyPath('/parent/in'),
        ], {})).dartValue,
        'source',
      );
    });
  }
}
