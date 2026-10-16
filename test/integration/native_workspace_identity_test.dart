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
    base = Directory('build').createTempSync('native-identity-');
    session = await pool.checkout();
  });
  tearDown(() async {
    await session.close();
    base.deleteSync(recursive: true);
  });

  // Both spellings must refuse even on normalization-sensitive volumes.
  for (final reversed in [false, true]) {
    final protected = reversed ? 'cafe\u0301' : 'caf\u00e9';
    final alias = reversed ? 'caf\u00e9' : 'cafe\u0301';
    final operations = {
      'write': "Path('files/$alias').write_text('changed')",
      'truncate': "open('files/$alias', 'w')",
      'rename source': "Path('files/$alias').rename('moved')",
      'rename destination': "Path('other/source').rename('files/$alias')",
      'mkdir': "Path('dir/$alias/new').mkdir()",
      'unlink': "Path('files/$alias').unlink()",
      'ancestor': "Path('parent/$alias').rename('moved')",
    };
    for (final operation in operations.entries) {
      test('native Unicode ${operation.key} $reversed', () async {
        final workspace = Workspace(
          sandboxBaseDir: base.path,
          files: {
            'files/$protected': 'seed',
            'other/source': 'other',
            'dir/$protected/seed': 'seed',
            'parent/$protected/child': 'seed',
          },
          readOnly: {
            'files/$protected',
            'dir/$protected',
            'parent/$protected/child',
          },
        );
        addTearDown(workspace.dispose);
        final result = await workspace.driver(session)(
          'from pathlib import Path\n'
          'try:\n    ${operation.value}\n    result = "accepted"\n'
          'except PermissionError:\n    result = "denied"\n'
          'except OSError:\n    result = "other error"\nresult',
        );
        expect(result, const MontyString('denied'));
        expect(workspace.writeBytes, 0);
        final read = await workspace.driver(session)(
          "[Path('files/$protected').read_text(), Path('other/source').read_text(), "
          "Path('dir/$protected/seed').read_text(), "
          "Path('parent/$protected/child').read_text()]",
        );
        expect(
          read,
          const MontyList([
            MontyString('seed'),
            MontyString('other'),
            MontyString('seed'),
            MontyString('seed'),
          ]),
        );
      });
    }
  }

  test('native Unicode transfer', () async {
    final workspace = Workspace(
      sandboxBaseDir: base.path,
      files: {'caf\u00e9': 'seed'},
      readOnly: {'caf\u00e9'},
    );
    addTearDown(workspace.dispose);
    final handler = workspace.compose(
      (_, _, _) => throw const OsCallNotHandledException(),
    );
    await expectLater(
      Future<MontyValue>.sync(
        () => handler('Path.write_text', [
          MontyPath('/work/cafe\u0301'),
          const MontyString('changed'),
        ], {}),
      ),
      throwsA(isA<ExternalException>()),
    );
    expect(workspace.writeBytes, 0);
    expect(
      await workspace.driver(session)(
        "from pathlib import Path\nPath('caf\u00e9').read_text()",
      ),
      const MontyString('seed'),
    );
  });

  test('native Unicode separate directory', () async {
    final workspace = Workspace(
      sandboxBaseDir: base.path,
      files: {'locked/caf\u00e9': 'seed'},
      readOnly: {'locked/caf\u00e9'},
      directories: {'writable'},
    );
    addTearDown(workspace.dispose);
    expect(
      await workspace.driver(session)(
        'from pathlib import Path\n'
        "Path('writable/cafe\u0301').write_text('new')\n"
        "sorted(p.name for p in Path('.').iterdir())",
      ),
      const MontyList([MontyString('locked'), MontyString('writable')]),
    );
    expect(workspace.writeBytes, 3);
  });

  for (final scenario in [
    (
      'root protected name does not block another root child',
      'caf\u00e9',
      'output.txt',
    ),
    ('distinct accents do not alias', 'caf\u00e9', 'caf\u00e8'),
    (
      'unrelated accented name does not alias',
      'config.txt',
      'r\u00e9sum\u00e9.txt',
    ),
  ]) {
    test('native Unicode ${scenario.$1}', () async {
      final workspace = Workspace(
        sandboxBaseDir: base.path,
        files: {scenario.$2: 'seed'},
        readOnly: {scenario.$2},
      );
      addTearDown(workspace.dispose);
      expect(
        await workspace.driver(session)(
          "from pathlib import Path\nPath('${scenario.$3}').write_text('new')\n"
          "[Path('${scenario.$2}').read_text(), "
          "Path('${scenario.$3}').read_text()]",
        ),
        const MontyList([MontyString('seed'), MontyString('new')]),
      );
      expect(workspace.writeBytes, 3);
    });
  }

  for (final replaceBase in [false, true]) {
    test('native cleanup replacement $replaceBase', () {
      final parent = Directory('${base.path}/parent')..createSync();
      final disk = createDiskBacking(parent.path, {
        '/work': null,
        '/work/seed': Uint8List.fromList([1]),
      });
      final owned = parent.listSync().singleOrNull! as Directory;
      final original = replaceBase ? parent : owned;
      final retained = original.renameSync('${base.path}/retained');
      final replacement = Directory('${owned.path}/work')
        ..createSync(recursive: true);
      File('${owned.path}/.owner').writeAsStringSync('0' * 64);
      final sentinel = File('${replacement.path}/seed')
        ..writeAsStringSync('replacement');
      final originalSeed = replaceBase
          ? '${retained.path}/${p.basename(owned.path)}/work/seed'
          : '${retained.path}/work/seed';
      expect(
        disk.dispose,
        throwsA(
          isA<ExternalException>().having(
            (error) => error.toString(),
            'message',
            contains('Workspace backing retained'),
          ),
        ),
      );
      expect(sentinel.readAsStringSync(), 'replacement');
      expect(File(originalSeed).readAsBytesSync(), [1]);
      expect(replacement.existsSync(), true);
    });
  }
}
