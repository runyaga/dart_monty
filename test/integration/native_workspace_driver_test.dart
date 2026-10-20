@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty/src/workspace/disk_backing_io.dart';
import 'package:dart_monty/src/workspace/persistent_transfer.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Directory base;
  late Monty pool;
  late MontySession session;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());
  setUp(() async {
    Directory('build').createSync();
    base = Directory('build').createTempSync('native-workspace-');
    session = await pool.checkout();
  });
  tearDown(() async {
    await session.close();
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('N2-intercept-before-mount', () async {
    final workspace = Workspace(
      sandboxBaseDir: base.path,
      files: {'locked': 'seed'},
      readOnly: {'locked'},
    );
    addTearDown(workspace.dispose);
    final result = await workspace.driver(session)('''
from pathlib import Path
try:
    Path('locked').write_text('changed')
except PermissionError as e:
    message = str(e)
(message, Path('locked').read_text())
''');
    expect(result.dartValue, [
      "[Errno 30] Read-only file system: '/work/locked'",
      'seed',
    ]);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    expect(File('${owned.path}/locked').readAsStringSync(), 'seed');
  });

  test('N3-native-lifecycle', () async {
    final parent = OSAccess();
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    final workspace = Workspace(sandboxBaseDir: base.path, parent: parent.call);
    await workspace.driver(session)('''
from pathlib import Path
Path('out').write_text('retained')
''');
    await session.close();
    for (final destination in ['/first', '/second']) {
      await transfers.collect(workspace, {'out': destination});
      expect(
        parent.call('Path.read_text', [MontyPath(destination)], {}),
        const MontyString('retained'),
      );
      expect(base.listSync(), hasLength(1));
    }
    await workspace.dispose();
    expect(base.listSync(), isEmpty);
    await workspace.dispose();
  });
  test('N1-snapshot-composition', () async {
    final w = Workspace(sandboxBaseDir: base.path);
    addTearDown(w.dispose);
    final started = <int>[];
    final completed = <int>[];
    final barrier = Completer<void>();
    final printed = CollectString();
    final value = await w.driver(session)(
      '''
import asyncio
import time
from pathlib import Path
print('before')
time.sleep(0.001)
async def task(n):
    return await tool(n)
values = await asyncio.gather(task(140), task(60), task(100), asyncio.sleep(0.001))
Path('result').write_text('ok')
print('after')
values
''',
      printCallback: printed.call,
      externalLookup: {
        'tool': MontyHostFunction(
          'tool',
          coroutine((args, _) async {
            final n = (args.single as MontyInt).value;
            started.add(n);
            if (started.length == 3) barrier.complete();
            await barrier.future.timeout(const Duration(seconds: 2));
            await Future<void>.delayed(Duration(milliseconds: n));
            completed.add(n);

            return MontyInt(n);
          }),
        ),
      },
    );
    expect(started, [140, 60, 100]);
    expect(completed, [60, 100, 140]);
    expect(value.dartValue, [140, 60, 100, null]);
    expect(printed.output, 'before\nafter\n');
  });

  test('N3-native-lifecycle-retry', () async {
    final parent = OSAccess();
    var fail = true;
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    final w = Workspace(
      sandboxBaseDir: base.path,
      files: {'a': 'first', 'b': 'second'},
      parent: (name, args, kwargs) {
        if (fail &&
            name == 'Path.write_bytes' &&
            args.first == MontyPath('/b')) {
          throw const ExternalException('OSError', 'second destination failed');
        }

        return parent.call(name, args, kwargs);
      },
    );
    addTearDown(w.dispose);
    await w.driver(session)('1');
    await session.close();
    await expectLater(
      transfers.collect(w, {'a': '/a', 'b': '/b'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      parent.call('Path.read_text', [MontyPath('/a')], {}),
      const MontyString('first'),
    );
    fail = false;
    await transfers.collect(w, {'a': '/a', 'b': '/b'});
    expect(
      parent.call('Path.read_text', [MontyPath('/b')], {}),
      const MontyString('second'),
    );
    expect(base.listSync(), hasLength(1));
  });

  test('N4-dispose-lease', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final parent = OSAccess();
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    final w = Workspace(
      sandboxBaseDir: base.path,
      files: {'out': 'value'},
      parent: (name, args, kwargs) async {
        if (name == 'Path.write_bytes') {
          entered.complete();
          await release.future;
        }

        return parent.call(name, args, kwargs);
      },
    );
    final collect = transfers.collect(w, {'out': '/out'});
    await entered.future;
    var disposed = false;
    final disposal = w.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, false);
    expect(base.listSync(), hasLength(1));
    await expectLater(transfers.collect(w, {'out': '/late'}), throwsStateError);
    release.complete();
    await collect;
    await disposal;
    expect(base.listSync(), isEmpty);
    expect(
      parent.call('Path.read_text', [MontyPath('/out')], {}),
      const MontyString('value'),
    );
    final other = Workspace(
      sandboxBaseDir: base.path,
      files: {'out': 'lost'},
      parent: parent.call,
    );
    final freeing = other.dispose();
    await expectLater(
      transfers.collect(other, {'out': '/never'}),
      throwsStateError,
    );
    await freeing;
    expect(
      parent.call('Path.exists', [MontyPath('/never')], {}),
      const MontyBool(false),
    );
  });

  test('N5-sleep-budget', () async {
    await session.close();
    session = await pool.checkout(
      limits: const ResourceLimits(maxTotalSleep: Duration(milliseconds: 30)),
    );
    final w = Workspace(sandboxBaseDir: base.path);
    addTearDown(w.dispose);
    expect(
      await w.driver(session)(
        'import time\nimport asyncio\ntime.sleep(0.01)\n'
        'await asyncio.sleep(0.01)\n42',
      ),
      const MontyInt(42),
    );
    await expectLater(
      w.driver(session)('time.sleep(0.02)'),
      throwsA(isA<MontyError>()),
    );
  });

  test('N6-independent-cleanup', () async {
    final w = Workspace(sandboxBaseDir: base.path);
    final calls = <String>[];
    await expectLater(
      cleanupWorkspace([
        () {
          calls.add('extension');
          throw StateError('extension close');
        },
        () async {
          calls.add('session');
          await session.close();
          throw StateError('session close');
        },
        () {
          calls.add('workspace');

          return w.dispose();
        },
      ]),
      throwsStateError,
    );
    expect(calls, ['extension', 'session', 'workspace']);
    expect(base.listSync(), isEmpty);
    await w.dispose();
    session = await pool.checkout();
    final recording = _MountRecordingSession(session);
    final active = Workspace(sandboxBaseDir: base.path);
    final entered = Completer<void>();
    final release = Completer<MontyValue>();
    final run = active.driver(recording)(
      'hold()',
      externalLookup: {
        'hold': MontyHostFunction('hold', (_, _) {
          entered.complete();

          return release.future;
        }),
      },
    );
    final ended = expectLater(run, throwsStateError);
    await entered.future;
    await expectLater(active.dispose(), throwsStateError);
    await ended;
    release.complete(const MontyNone());
    expect(base.listSync(), isEmpty);
    final probe = await pool.checkout();
    try {
      await expectLater(
        probe.feedRun('1', mount: recording.mounts),
        throwsStateError,
      );
    } finally {
      await probe.close();
    }
  });

  test('N7-backing-aliases', () async {
    final w = Workspace(
      sandboxBaseDir: base.path,
      files: {'safe': 'safe'},
      directories: {'dir'},
    );
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    final outside = Directory('${base.path}/outside')..createSync();
    File('${outside.path}/secret').writeAsStringSync('unchanged');
    Link('${owned.path}/escape').createSync(outside.absolute.path);
    await expectLater(
      w.driver(session)(
        "from pathlib import Path\nPath('escape/secret').write_text('bad')",
      ),
      throwsA(isA<MontyError>()),
    );
    expect(File('${outside.path}/secret').readAsStringSync(), 'unchanged');
    Link('${owned.path}/escape').deleteSync();
    Link('${owned.path}/dir/escape').createSync(outside.absolute.path);
    await expectLater(
      w.driver(session)("Path('dir').rename('moved')"),
      throwsA(isA<MontyError>()),
    );
    expect(Directory('${owned.path}/dir').existsSync(), true);
    expect(Directory('${owned.path}/moved').existsSync(), false);
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await expectLater(
      transfers.collect(w, {'dir': '/out'}),
      throwsA(isA<ExternalException>()),
    );
  });

  test('B-native-direct-bounded-read', () async {
    final disk = createDiskBacking(base.path, {
      '/work': null,
      '/work/a': Uint8List.fromList([1]),
    });
    addTearDown(disk.dispose);
    expect((await disk.snapshot(maxBytes: 1))['/work/a'], [1]);
    await expectLater(
      disk.snapshot(maxBytes: 0),
      throwsA(isA<ExternalException>()),
    );
  });

  test('B-native-traversal-occurrences', () async {
    final disk = createDiskBacking(base.path, {
      '/work': null,
      '/work/empty': null,
    });
    addTearDown(disk.dispose);
    expect(
      await disk.snapshot(
        maxBytes: 0,
        roots: const ['/work/empty', '/work/empty'],
        maxEntries: 2,
      ),
      {'/work/empty': null},
    );
    await expectLater(
      disk.snapshot(
        maxBytes: 0,
        roots: const ['/work/empty', '/work/empty', '/work/empty'],
        maxEntries: 2,
      ),
      throwsA(isA<ExternalException>()),
    );
  });

  test('B-native-bounded-read', () async {
    final parent = OSAccess();
    final w = Workspace(
      sandboxBaseDir: base.path,
      parent: parent.call,
      memoryUsageLimit: null,
    );
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    File('${owned.path}/large').openSync(mode: FileMode.write)
      ..truncateSync(8388609)
      ..closeSync();
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await expectLater(
      transfers.collect(w, {'large': '/out'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      parent.call('Path.exists', [MontyPath('/out')], {}),
      const MontyBool(false),
    );
  });

  test('N-fake-native-mount', () async {
    final fake = FakeMontySession()
      ..willCallOs(
        'Path.write_text',
        args: [MontyPath('/work/fake'), const MontyString('real disk')],
      )
      ..willReturn(const MontyNone());
    final w = Workspace(sandboxBaseDir: base.path);
    addTearDown(w.dispose);
    addTearDown(fake.close);
    await w.driver(fake)('scripted');
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    expect(File('${owned.path}/fake').readAsStringSync(), 'real disk');
  });

  test('T-native-persistent-parent-cwd', () async {
    final parent = Workspace(
      sandboxBaseDir: base.path,
      files: {'input': 'parent'},
      directories: {'nested'},
    );
    addTearDown(parent.dispose);
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    final adapter = parent.compose(
      (_, _, _) => throw const OsCallNotHandledException(),
    );
    final result = await parent.driver(session)(
      '''
import os
from pathlib import Path
os.chdir('/work/nested')
transfer()
Path('/work/output').read_text()
''',
      externalLookup: {
        'transfer': MontyHostFunction('transfer', (_, _) async {
          final child = await transfers.copyIn(
            sandboxBaseDir: base.path,
            parent: adapter,
            files: {'in': '/work/input'},
          );
          try {
            final execution = await pool.checkout();
            try {
              await child.driver(execution)(
                'from pathlib import Path\n'
                "Path('out').write_text(Path('in').read_text() + '-child')",
              );
            } finally {
              await execution.close();
            }
            await transfers.collect(child, {'out': '/work/output'});
            await expectLater(
              transfers.collect(child, {'out': 'relative'}),
              throwsA(isA<ExternalException>()),
            );

            return const MontyNone();
          } finally {
            await child.dispose();
          }
        }),
      },
    );
    expect(result, const MontyString('parent-child'));
    expect(parent.writeBytes, 12);
  });

  test('T-native-overlay-and-read-only-adapters', () async {
    final root = Directory('${base.path}/mounted')..createSync();
    File('${root.path}/seed').writeAsStringSync('disk');
    final overlay = MountDir(hostPath: root.path, virtualPath: '/work');
    final readonly = MountDir(
      hostPath: root.path,
      virtualPath: '/work',
      mode: 'read-only',
    );
    addTearDown(overlay.close);
    addTearDown(readonly.close);
    final finite = await startTestPool(
      maxProcesses: 1,
      checkoutTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(finite.close);
    final held = await finite.checkout();
    final adapter = PersistentTransfer(finite, [overlay]);
    await expectLater(
      adapter.call('Path.stat', [MontyPath('/work/seed')], {}),
      throwsA(isA<ExternalException>()),
    );
    final persistent = PersistentTransfer(finite, [readonly]);
    await expectLater(
      persistent.call('Path.stat', [MontyPath('/work/seed')], {}),
      throwsA(isA<TimeoutException>()),
    );
    await held.close();
    expect(
      await persistent.call('Path.stat', [MontyPath('/work/seed')], {}),
      isA<MontyNamedTuple>(),
    );
    await expectLater(
      persistent.call('Path.write_bytes', [
        MontyPath('/work/seed'),
        MontyBytes(Uint8List.fromList([1])),
      ], {}),
      throwsA(isA<ExternalException>()),
    );
    expect(File('${root.path}/seed').readAsStringSync(), 'disk');
  });

  test('workspace transfers enforce capacity limits', () async {
    final root = Directory('${base.path}/capacity')..createSync();
    final readonly = MountDir(
      hostPath: root.path,
      virtualPath: '/work',
      mode: 'read-only',
    );
    addTearDown(readonly.close);
    final finite = await startTestPool(
      maxProcesses: 1,
      checkoutTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(finite.close);
    final held = await finite.checkout();
    addTearDown(held.close);
    final adapter = PersistentTransfer(finite, [readonly]);
    await expectLater(
      adapter.call('Path.write_bytes', [
        MontyPath('/work/no-write'),
        MontyBytes(Uint8List(1)),
      ], {}),
      throwsA(isA<ExternalException>()),
    );
    await expectLater(
      adapter.call('Path.stat', [MontyPath('/work')], {}),
      throwsA(isA<TimeoutException>()),
    );
    expect(root.listSync(), isEmpty);
    await held.close();
    expect(
      await adapter.call('Path.stat', [MontyPath('/work')], {}),
      isA<MontyNamedTuple>(),
    );
  });

  test('N-caps-lifetime-and-rejection', () async {
    final w = Workspace(sandboxBaseDir: base.path, writeBytesLimit: 3);
    addTearDown(w.dispose);
    await w.driver(session)(
      'from pathlib import Path\n'
      "Path('a').write_text('ab')\nPath('a').unlink()",
    );
    expect(w.writeBytes, 2);
    await expectLater(
      w.driver(session)("Path('a').write_text('cd')"),
      throwsA(isA<MontyError>()),
    );
    expect(w.writeBytes, 2);
    expect(w.memoryUsage, 64);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    expect(owned.listSync(), isEmpty);
    await w.driver(session)("Path('a').write_text('x')");
    expect(w.writeBytes, 3);
  });

  test('N-caps-identical-write-charged', () async {
    final w = Workspace(sandboxBaseDir: base.path);
    addTearDown(w.dispose);
    await w.driver(session)(
      'from pathlib import Path\n'
      "Path('a').write_text('x')\nPath('a').write_text('x')",
    );
    expect(w.writeBytes, 2);
  });

  for (final operation in [
    "Path('locked').write_text('x')",
    "Path('locked').write_bytes(b'x')",
    "open('locked', 'w')",
    "open('locked', 'a')",
    "Path('locked').unlink()",
    "Path('locked').rename('other')",
    "Path('other').rename('locked')",
    "Path('dir').rename('moved')",
    "Path('dir').rmdir()",
    "Path('dir/new').mkdir()",
  ]) {
    test('N-read-only-$operation', () async {
      final w = Workspace(
        sandboxBaseDir: base.path,
        files: {'locked': 'seed', 'other': 'other', 'dir/seed': 'seed'},
        readOnly: {'locked', 'dir'},
      );
      addTearDown(w.dispose);
      final value = await w.driver(session)(
        'from pathlib import Path\n'
        'try:\n    $operation\n    result = "accepted"\n'
        'except PermissionError:\n    result = "denied"\nresult',
      );
      expect(value, const MontyString('denied'));
      expect(w.writeBytes, 0);
    });
  }

  test('N-cwd-persistence', () async {
    final w = Workspace(sandboxBaseDir: base.path, directories: {'nested'});
    addTearDown(w.dispose);
    await w.driver(session)("import os\nos.chdir('/work/nested')");
    expect(
      await w.driver(session)('os.getcwd()', cwd: null),
      const MontyString('/work/nested'),
    );
    expect(await w.driver(session)('os.getcwd()'), const MontyString('/work'));
  });

  test('B-native-selected-sources-only', () async {
    final parent = OSAccess();
    final w = Workspace(
      sandboxBaseDir: base.path,
      files: {'small': 'ok'},
      parent: parent.call,
    );
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    File('${owned.path}/unselected').openSync(mode: FileMode.write)
      ..truncateSync(8388609)
      ..closeSync();
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await transfers.collect(w, {'small': '/out'});
    expect(
      parent.call('Path.read_text', [MontyPath('/out')], {}),
      const MontyString('ok'),
    );
  });
  test('B-native-transfer-bytes-and-aliases', () async {
    final parent = OSAccess();
    final w = Workspace(
      sandboxBaseDir: base.path,
      parent: parent.call,
      memoryUsageLimit: null,
    );
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    final file = File('${owned.path}/large');
    file.openSync(mode: FileMode.write)
      ..truncateSync(4194304)
      ..closeSync();
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await transfers.collect(w, {'large': '/one', './large': '/two'});
    expect(
      (parent.call('Path.read_bytes', [MontyPath('/two')], {}) as MontyBytes)
          .value
          .length,
      4194304,
    );
    file.openSync(mode: FileMode.append)
      ..truncateSync(4194305)
      ..closeSync();
    await expectLater(
      transfers.collect(w, {'large': '/bad1', './large': '/bad2'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      parent.call('Path.exists', [MontyPath('/bad1')], {}),
      const MontyBool(false),
    );
  });

  test('B-native-transfer-entries', () async {
    final parent = OSAccess();
    final w = Workspace(sandboxBaseDir: base.path, parent: parent.call);
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    final dir = Directory('${owned.path}/bulk')..createSync();
    for (var i = 0; i < 4095; i++) {
      File('${dir.path}/f$i').writeAsStringSync('');
    }
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await transfers.collect(w, {'bulk': '/ok'});
    expect(
      (parent.call('Path.iterdir', [MontyPath('/ok')], {}) as MontyList).items,
      hasLength(4095),
    );
    File('${dir.path}/overflow').writeAsStringSync('');
    await expectLater(
      transfers.collect(w, {'bulk': '/bad'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      parent.call('Path.exists', [MontyPath('/bad')], {}),
      const MontyBool(false),
    );
  });

  test('B-native-transfer-depth', () async {
    final parent = OSAccess();
    final w = Workspace(sandboxBaseDir: base.path, parent: parent.call);
    addTearDown(w.dispose);
    final owned = Directory(
      '${(base.listSync().single as Directory).path}/work',
    );
    final deep = '${owned.path}/tree${'/d' * 32}';
    Directory(deep).createSync(recursive: true);
    final transfers = WorkspaceTransfers();
    addTearDown(transfers.dispose);
    await transfers.collect(w, {'tree': '/ok'});
    Directory('$deep/overflow').createSync();
    await expectLater(
      transfers.collect(w, {'tree': '/bad'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      parent.call('Path.exists', [MontyPath('/bad')], {}),
      const MontyBool(false),
    );
  });

  test('N-print-error-frames', () async {
    final w = Workspace(sandboxBaseDir: base.path);
    addTearDown(w.dispose);
    final prints = CollectString();
    final oraclePrints = CollectString();
    const code = 'print("before error")\n1 / 0';
    MontyError? manual;
    MontyError? automatic;
    try {
      await w.driver(session)(code, printCallback: prints.call);
    } on MontyError catch (e) {
      manual = e;
    }
    final oracle = await pool.checkout();
    try {
      await oracle.feedRun(code, printCallback: oraclePrints.call);
    } on MontyError catch (e) {
      automatic = e;
    } finally {
      await oracle.close();
    }
    expect(manual, isA<MontyRuntimeError>());
    expect(automatic, isA<MontyRuntimeError>());
    expect(manual?.exception.excType, automatic?.exception.excType);
    expect(manual?.exception.message, automatic?.exception.message);
    expect(
      (manual as MontyRuntimeError?)?.display(),
      (automatic as MontyRuntimeError?)?.display(),
    );
    expect(prints.output, oraclePrints.output);
    expect(prints.output, 'before error\n');
  });
  for (final entry in diskParity.entries) {
    test('P-${entry.key}', () async {
      final w = Workspace(sandboxBaseDir: base.path, files: {'seed': 'seed'});
      addTearDown(w.dispose);
      final oracleRoot = Directory('${base.path}/oracle')..createSync();
      File('${oracleRoot.path}/seed').writeAsStringSync('seed');
      final oracleMount = MountDir(
        hostPath: oracleRoot.path,
        virtualPath: '/work',
        mode: 'read-write',
      );
      addTearDown(oracleMount.close);
      final oracle = await pool.checkout();
      addTearDown(oracle.close);
      final automaticPrints = CollectString();
      final manualPrints = CollectString();
      final code = 'from pathlib import Path\nimport os\n${entry.value}';
      final expected = await oracle.feedRun(
        code,
        mount: [oracleMount],
        cwd: '/work',
        printCallback: automaticPrints.call,
      );
      final actual = await w.driver(session)(
        code,
        printCallback: manualPrints.call,
      );
      expect(actual.dartValue, expected.dartValue);
      expect(manualPrints.output, automaticPrints.output);
    });
  }
}

const diskParity = <String, String>{
  '01-read': "Path('seed').read_text()",
  '02-write': "Path('out').write_text('é')\nPath('out').read_text()",
  '03-bytes': "Path('out').write_bytes(b'abc')\nPath('out').read_bytes()",
  '04-append':
      "f = open('seed', 'a')\n"
      "f.write('!')\n"
      'f.close()\n'
      "Path('seed').read_text()",
  '05-truncate': "open('seed', 'w').close()\nPath('seed').read_text()",
  '06-mkdir': "Path('a/b').mkdir(parents=True)\nPath('a/b').is_dir()",
  '07-list': "sorted([str(p) for p in Path('.').iterdir()])",
  '08-rename':
      "Path('seed').rename('moved')\n"
      "(Path('seed').exists(), Path('moved').read_text())",
  '09-replace':
      "Path('dest').write_text('old')\n"
      "Path('seed').rename('dest')\n"
      "Path('dest').read_text()",
  '10-unlink': "Path('seed').unlink()\nPath('seed').exists()",
  '11-rmdir':
      "Path('empty').mkdir()\nPath('empty').rmdir()\nPath('empty').exists()",
  '12-cwd':
      "Path('dir').mkdir()\n"
      "os.chdir('/work/dir')\n"
      "Path('out').write_text('x')\n"
      "(os.getcwd(), Path('../dir/out').read_text())",
  '13-errors':
      'try:\n'
      "    Path('missing').read_text()\n"
      'except FileNotFoundError as e:\n'
      '    result = type(e).__name__\n'
      'result',
  '14-print': "print(Path('seed').read_text())\n42",
  '15-open-exclusive':
      'try:\n'
      "    open('out', 'x')\n"
      'except ValueError as e:\n'
      '    result = str(e)\n'
      'result',
};

final class _MountRecordingSession implements MontySession {
  _MountRecordingSession(this.inner);
  final MontySession inner;
  List<MountDir>? mounts;

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    FutureOr<void> Function(String, String)? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) {
    mounts = mount;

    return inner.feedStart(
      code,
      inputs: inputs,
      externalLookup: externalLookup,
      printCallback: printCallback,
      mount: mount,
      cwd: cwd,
      os: os,
      skipTypeCheck: skipTypeCheck,
    );
  }

  @override
  Future<void> close() async {
    await inner.close();
    throw StateError('session close failed after release');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected session operation: ${invocation.memberName}',
  );
}
