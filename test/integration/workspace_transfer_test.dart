@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_workspace_harness.dart';

void main() {
  final h = WorkspaceHarness()..install();
  late WorkspaceTransfers transfers;
  late OSAccess parent;
  setUp(() {
    transfers = WorkspaceTransfers();
    parent = OSAccess(files: [MemoryFile('/parent/in', 'source')]);
  });
  test('D4a-empty-work', () async {
    final w = await transfers.copyIn();
    addTearDown(w.dispose);
    final bridge = SessionBridge(session: h.session)..registerOs(w.call);
    addTearDown(bridge.dispose);
    final events = await bridge
        .executeWith(
          "import os\nfrom pathlib import Path\n(os.getcwd(), Path('.').is_dir())",
          cwd: '/work',
        )
        .toList();
    expect((events.last as BridgeRunFinished).value, ['/work', true]);
  });
  test('D4a-captured-context', () async {
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
        const MontyPath('/parent/out'),
      ], {})).dartValue,
      'child',
    );
    expect(
      (await parent.call('Path.exists', [
        const MontyPath('/parent/out'),
      ], {})).dartValue,
      false,
    );
  });
  test('D4a-missing-adapter', () async {
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
  test('D4a-protected-rename', () async {
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
  test('D4a-staging-failure', () async {
    final w = await transfers.copyIn(parent: parent.call);
    addTearDown(w.dispose);
    await h.run(w, "Path('a').write_text('ok')");
    await expectLater(
      transfers.collect(w, {'a': '/parent/a', 'missing': '/parent/b'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await parent.call('Path.exists', [
        const MontyPath('/parent/a'),
      ], {})).dartValue,
      false,
    );
    expect(w.writeBytes, 2);
  });
  test('D4a-collect-retry', () async {
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
      "Path('a').write_text('one')\nPath('b').write_text('two')\nPath('a').rename('renamed')",
    );
    const selection = {'renamed': '/parent/a', 'b': '/parent/b'};
    await expectLater(
      transfers.collect(w, selection),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await parent.call('Path.read_text', [
        const MontyPath('/parent/a'),
      ], {})).dartValue,
      'one',
    );
    reject = false;
    await transfers.collect(w, selection);
    await transfers.collect(w, selection);
    expect(
      (await parent.call('Path.read_text', [
        const MontyPath('/parent/b'),
      ], {})).dartValue,
      'two',
    );
  });
  test('T1-absolute-cwd', () async {
    await h.session.feedRun("import os\nos.chdir('/parent')", os: parent.call);
    final w = await transfers.copyIn(
      parent: parent.call,
      files: {'in': '/parent/in'},
    );
    addTearDown(w.dispose);
    await h.run(w, "Path('in').write_text('independent')");
    await h.session.feedRun("import os\nos.chdir('/')", os: parent.call);
    await transfers.collect(w, {'in': '/parent/out'});
    expect(
      (await parent.call('Path.read_text', [
        const MontyPath('/parent/in'),
      ], {})).dartValue,
      'source',
    );
    await expectLater(
      transfers.copyIn(parent: parent.call, files: {'in': 'parent/in'}),
      throwsA(isA<ExternalException>()),
    );
    await expectLater(
      transfers.collect(w, {'in': 'relative'}),
      throwsA(isA<ExternalException>()),
    );
  });
  test('T2-overlay-rejection', () async {
    // A mount-only parent has no captured live callback. Sharing a fresh
    // mount table is deliberately not an adapter. D4b owns native adapters.
    final overlay = OSAccess(files: [MemoryFile('/overlay/only', 'live')]);
    await h.session.feedRun(
      "from pathlib import Path\nPath('/overlay/only').write_text('suspended state')",
      os: overlay.call,
    );
    await expectLater(
      transfers.copyIn(files: {'in': '/overlay/only'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await overlay.call('Path.read_text', [
        const MontyPath('/overlay/only'),
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
    await transfers.collect(w, {'in': '/parent/out'});
    expect(
      await h.session.feedRun(
        "Path('/parent/out').read_text()",
        os: parent.call,
      ),
      const MontyString('result'),
    );
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
    expect(disposed, false);
    release.complete();
    await collecting;
    await disposing;
    expect(w.memoryUsage, 0);
    await expectLater(
      transfers.collect(w, {'a': '/parent/b'}),
      throwsStateError,
    );
    expect(
      (await parent.call('Path.exists', [
        const MontyPath('/parent/b'),
      ], {})).dartValue,
      false,
    );
  });
}
