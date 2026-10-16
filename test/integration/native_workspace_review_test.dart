@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty/src/workspace/disk_backing_io.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;
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
    base = Directory('build').createTempSync('native-review-');
    session = await pool.checkout();
  });
  tearDown(() async {
    await session.close();
    base.deleteSync(recursive: true);
  });

  final operations = [
    "Path('LOCKED').write_text('x')",
    "Path('LOCKED').write_bytes(b'x')",
    "open('LOCKED', 'w')",
    "open('LOCKED', 'a')",
    "Path('LOCKED').unlink()",
    "Path('LOCKED').rename('moved')",
    "Path('other').rename('LOCKED')",
    "Path('DIR/new').mkdir()",
    "Path('DIR').rename('moved')",
    "Path('PARENT').rename('moved')",
  ];
  for (var i = 0; i < operations.length; i++) {
    test('N8-policy-consistency-$i', () async {
      final workspace = Workspace(
        sandboxBaseDir: base.path,
        files: {
          'locked': 'seed',
          'other': 'other',
          'dir/seed': 'seed',
          'parent/child': 'seed',
        },
        readOnly: {'locked', 'dir', 'parent/child'},
      );
      addTearDown(workspace.dispose);
      final result = await workspace.driver(session)(
        'from pathlib import Path\n'
        'try:\n    ${operations[i]}\n    result = "accepted"\n'
        'except PermissionError:\n    result = "denied"\nresult',
      );
      expect(result, const MontyString('denied'));
      expect(workspace.writeBytes, 0);
      final owned = _owned(base);
      expect(File('${owned.path}/work/locked').readAsStringSync(), 'seed');
      expect(File('${owned.path}/work/dir/seed').readAsStringSync(), 'seed');
      expect(
        File('${owned.path}/work/parent/child').readAsStringSync(),
        'seed',
      );
    });
  }

  test('N8-policy-transfer', () async {
    final workspace = Workspace(
      sandboxBaseDir: base.path,
      files: {'locked': 'seed'},
      readOnly: {'locked'},
    );
    addTearDown(workspace.dispose);
    final handler = workspace.compose(
      (_, _, _) => throw const OsCallNotHandledException(),
    );
    await expectLater(
      Future<MontyValue>.sync(
        () => handler('Path.write_bytes', [
          MontyPath('/work/LOCKED'),
          MontyBytes(Uint8List.fromList([1])),
        ], {}),
      ),
      throwsA(isA<ExternalException>()),
    );
    expect(workspace.writeBytes, 0);
    final owned = _owned(base);
    expect(File('${owned.path}/work/locked').readAsStringSync(), 'seed');
  });

  for (final relocated in [false, true]) {
    test('N9-cleanup-identity-$relocated', () {
      final parent = Directory('${base.path}/parent')..createSync();
      final disk = createDiskBacking(parent.path, {
        '/work': null,
        '/work/seed': Uint8List.fromList([1]),
      });
      final owned = _owned(parent);
      final name = p.basename(owned.path);
      final retained = parent.renameSync('${base.path}/retained');
      final outside = Directory('${base.path}/outside/$name')
        ..createSync(recursive: true);
      final sentinel = File('${outside.path}/seed')
        ..writeAsStringSync('outside');
      Link(parent.path).createSync(
        relocated ? retained.absolute.path : outside.parent.absolute.path,
      );
      expect(disk.dispose, throwsA(isA<ExternalException>()));
      expect(sentinel.readAsStringSync(), 'outside');
      expect(File('${retained.path}/$name/work/seed').readAsBytesSync(), [1]);
      expect(Link(parent.path).existsSync(), true);
    });
  }

  test('N9-cleanup-root', () {
    final disk = createDiskBacking(base.path, {'/work': null});
    final owned = _owned(base);
    final retained = owned.renameSync('${base.path}/retained');
    Link(owned.path).createSync(retained.absolute.path);
    expect(disk.dispose, throwsA(isA<ExternalException>()));
    expect(Link(owned.path).existsSync(), true);
    expect(retained.existsSync(), true);
  });

  for (final caught in [false, true]) {
    test('N10-write-accounting-$caught', () async {
      final workspace = Workspace(
        sandboxBaseDir: base.path,
        writeBytesLimit: 1,
      );
      addTearDown(workspace.dispose);
      const failedWrite = "Path('a' * 256).write_text('x')";
      if (caught) {
        expect(
          await workspace.driver(session)(
            'from pathlib import Path\n'
            'try:\n    $failedWrite\n'
            'except OSError:\n    pass\n'
            "Path('valid').write_text('x')",
          ),
          const MontyInt(1),
        );
      } else {
        await expectLater(
          workspace.driver(session)(
            'from pathlib import Path\n$failedWrite',
          ),
          throwsA(isA<MontyRuntimeError>()),
        );
        expect(workspace.writeBytes, 0);
        expect(workspace.memoryUsage, 64);
        await workspace.driver(session)("Path('valid').write_text('x')");
      }
      expect(workspace.writeBytes, 1);
      expect(workspace.memoryUsage, 129);
      final owned = _owned(base);
      expect(File('${owned.path}/work/valid').readAsStringSync(), 'x');
    });
  }

  test('N10-write-completion', () async {
    final workspace = Workspace(
      sandboxBaseDir: base.path,
      writeBytesLimit: 1,
    );
    addTearDown(workspace.dispose);
    final run = workspace.driver(session);
    final runtimeError = throwsA(isA<MontyRuntimeError>());
    await expectLater(
      run(
        'from pathlib import Path\n'
        "Path('valid').write_text('x')\n1 / 0",
      ),
      runtimeError,
    );
    expect(workspace.writeBytes, 1);
    expect(workspace.memoryUsage, 129);
    await expectLater(
      run("Path('valid').write_text('y')"),
      runtimeError,
    );
    final owned = _owned(base);
    expect(File('${owned.path}/work/valid').readAsStringSync(), 'x');
  });
}

Directory _owned(Directory parent) {
  final entries = parent.listSync(followLinks: false);
  expect(entries, hasLength(1));

  return entries.singleOrNull! as Directory;
}
