import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../integration/_workspace_harness.dart';

void main() => registerBoundsTests();

void registerBoundsTests({String? Function()? backing}) {
  final h = WorkspaceHarness()..install();
  late WorkspaceTransfers transfers;
  setUp(() {
    transfers = WorkspaceTransfers();
  });
  tearDown(() => transfers.dispose());
  test('B-default-caps', () async {
    final defaults = SandboxExtension();
    expect(defaults.writeBytesLimit, 8388608);
    expect(defaults.memoryUsageLimit, 8388608);
    final unlimited = SandboxExtension(
      writeBytesLimit: null,
      memoryUsageLimit: null,
    );
    expect(unlimited.writeBytesLimit, isNull);
    expect(unlimited.memoryUsageLimit, isNull);
    for (final build in [
      () => SandboxExtension(writeBytesLimit: -1),
      () => SandboxExtension(memoryUsageLimit: -1),
      () => SandboxExtension(maxChildren: -1),
    ]) {
      expect(build, throwsArgumentError);
    }
    expect(() => reduceWorkspaceCap(2, 3), throwsArgumentError);
    expect(reduceWorkspaceCap(null, 3), 3);
    final w = Workspace(sandboxBaseDir: backing?.call());
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('.').is_dir()"), true);
  });
  test('B-transfer-bytes', () async {
    final parent = OSAccess(
      files: [
        MemoryFile('/a', Uint8List(4194304)),
        MemoryFile('/b', Uint8List(4194304)),
        MemoryFile('/c', Uint8List(1)),
      ],
    );
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {'a': '/a', 'b': '/b'},
      memoryUsageLimit: null,
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('b').stat().st_size"), 4194304);
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: parent.call,
        files: {'a': '/a', 'b': '/b', 'c': '/c'},
        memoryUsageLimit: null,
      ),
      throwsA(isA<ExternalException>()),
    );
    final huge = Workspace(
      sandboxBaseDir: backing?.call(),
      files: {'a': Uint8List(4194304), 'b': Uint8List(4194305)},
      memoryUsageLimit: null,
      parent: parent.call,
    );
    addTearDown(huge.dispose);
    await expectLater(
      transfers.collect(huge, {'a': '/outA', 'b': '/outB'}),
      throwsA(isA<ExternalException>()),
    );
    expect(
      (await parent.call('Path.exists', [MontyPath('/outA')], {})).dartValue,
      false,
    );
  });
  test('B-transfer-aliases', () async {
    final parent = OSAccess(files: [MemoryFile('/a', Uint8List(4194304))]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {'a': '/a', 'b': '/a'},
      memoryUsageLimit: null,
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('a').stat().st_size"), 4194304);
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: parent.call,
        files: {'a': '/a', 'b': '/a', 'c': '/a'},
        memoryUsageLimit: null,
      ),
      throwsA(isA<ExternalException>()),
    );
  });
  test('B-transfer-entries', () async {
    final parent = OSAccess(
      files: [for (var i = 0; i < 4096; i++) MemoryFile('/d/f$i', '')],
    );
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {for (var i = 0; i < 4096; i++) 'f$i': '/d/f$i'},
      memoryUsageLimit: null,
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "len(list(Path('.').iterdir()))"), 4096);
    // Selected root directory also counts: 4096 descendants + root = 4097.
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: parent.call,
        files: {'d': '/d'},
        memoryUsageLimit: null,
      ),
      throwsA(isA<ExternalException>()),
    );
  });
  test('B-transfer-depth', () async {
    final path = '/root/${List.filled(31, 'd').join('/')}/a';
    final parent = OSAccess(files: [MemoryFile(path, 'x')]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {'root': '/root'},
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('root').is_dir()"), true);
    final deeper = OSAccess(
      files: [MemoryFile('/root/d${path.substring(5)}', 'x')],
    );
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: deeper.call,
        files: {'root': '/root'},
      ),
      throwsA(isA<ExternalException>()),
    );
  });
  test('B-transfer-path', () async {
    if (backing != null) {
      // Host NAME_MAX/PATH_MAX can be lower than the virtual transfer limit.
      // Exercise the exact boundary on a memory destination from native data.
      final parent = OSAccess();
      final w = Workspace(
        sandboxBaseDir: backing(),
        files: {'a': 'x'},
        parent: parent.call,
      );
      addTearDown(w.dispose);
      final destination = '/${'a' * 4095}';
      await transfers.collect(w, {'a': destination});
      await expectLater(
        transfers.collect(w, {'a': '${destination}a'}),
        throwsA(isA<ExternalException>()),
      );
      expect(
        parent.call('Path.read_text', [MontyPath(destination)], {}),
        const MontyString('x'),
      );
      return;
    }
    final name = 'a' * 4090;
    final parent = OSAccess(files: [MemoryFile('/a', 'x')]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {name: '/a'},
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "len(list(Path('.').iterdir()))"), 1);
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: parent.call,
        files: {'${name}a': '/a'},
      ),
      throwsA(isA<ExternalException>()),
    );
  });
  test('B-transfer-symlink', () async {
    var descended = false;
    final parent = OSAccess(files: [MemoryFile('/root/a', 'x')]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('.').is_dir()"), true);
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: (name, args, kwargs) {
          if (name == 'Path.is_symlink') return const MontyBool(true);
          descended = true;
          return parent.call(name, args, kwargs);
        },
        files: {'root': '/root'},
      ),
      throwsA(isA<ExternalException>()),
    );
    expect(descended, false);
  });
  test('B-transfer-growth', () async {
    final parent = OSAccess(files: [MemoryFile('/a', 'x')]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: parent.call,
      files: {'a': '/a'},
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('a').read_text()"), 'x');
    await expectLater(
      transfers.copyIn(
        sandboxBaseDir: backing?.call(),
        parent: (name, args, kwargs) {
          if (name == 'Path.stat') return StatResult.fileStat(0);
          return parent.call(name, args, kwargs);
        },
        files: {'a': '/a'},
      ),
      throwsA(isA<ExternalException>()),
    );
  });
  test('B-collect-descendant-symlink', () async {
    final parent = OSAccess(
      files: [MemoryFile('/out/a', 'original'), MemoryFile('/out/b', 'target')],
    );
    var writes = 0;
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: (name, args, kwargs) {
        if (name == 'Path.is_symlink' && args.first.dartValue == '/out/b') {
          return const MontyBool(true);
        }
        if (name == 'Path.mkdir' || name == 'Path.write_bytes') writes++;

        return parent.call(name, args, kwargs);
      },
    );
    addTearDown(w.dispose);
    await h.run(
      w,
      "Path('d').mkdir()\nPath('d/a').write_text('new')\n"
      "Path('d/b').write_text('new')",
    );
    await expectLater(
      transfers.collect(w, {'d': '/out'}),
      throwsA(isA<ExternalException>()),
    );
    expect(writes, 0);
    expect(
      (await parent.call('Path.read_text', [
        MontyPath('/out/a'),
      ], {})).dartValue,
      'original',
    );
  });
  test('B-transfer-serial', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final parent = OSAccess(files: [MemoryFile('/a', 'x')]);
    final w = await transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: (name, args, kwargs) async {
        if (name == 'Path.write_bytes') {
          entered.complete();
          await release.future;
        }
        return parent.call(name, args, kwargs);
      },
      files: {'a': '/a'},
    );
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('a').read_text()"), 'x');
    final collecting = transfers.collect(w, {'a': '/out'});
    await entered.future;
    var reads = 0;
    final copying = transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: (name, args, kwargs) {
        reads++;
        return parent.call(name, args, kwargs);
      },
      files: {'a': '/a'},
    );
    await expectLater(transfers.collect(w, {'a': '/second'}), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    try {
      expect(reads, 0);
    } finally {
      release.complete();
    }
    await collecting;
    final copy = await copying;
    addTearDown(copy.dispose);
    expect(reads, greaterThan(0));
  });
  test('B-transfer-release', () async {
    final parent = OSAccess(files: [MemoryFile('/a', Uint8List(8388608))]);
    var reject = true;
    Future<Workspace> copy() => transfers.copyIn(
      sandboxBaseDir: backing?.call(),
      parent: (name, args, kwargs) {
        if (name == 'Path.read_bytes' && reject) {
          throw const ExternalException('OSError', 'failed read');
        }
        return parent.call(name, args, kwargs);
      },
      files: {'a': '/a'},
      memoryUsageLimit: null,
    );
    await expectLater(copy(), throwsA(isA<ExternalException>()));
    reject = false;
    final w = await copy();
    addTearDown(w.dispose);
    expect(await h.run(w, "Path('a').stat().st_size"), 8388608);
  });
}
