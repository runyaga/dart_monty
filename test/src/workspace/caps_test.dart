import 'dart:typed_data';

import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../integration/_workspace_harness.dart';

void main() => registerCapsTests();

void registerCapsTests({String? Function()? backing}) {
  final h = WorkspaceHarness()..install();
  late Workspace w;
  setUp(() {
    w = Workspace(sandboxBaseDir: backing?.call());
    addTearDown(w.dispose);
  });
  tearDown(() => w.dispose());
  test('seeded files retain their memory charge', () async {
    w = Workspace(
      sandboxBaseDir: backing?.call(),
      files: {
        'a': 'é',
        'd/b': Uint8List.fromList([1, 2, 3]),
      },
    );
    expect(w.memoryUsage, 4 * 64 + 5);
    expect(w.writeBytes, 0);
    expect(await h.run(w, "Path('a').read_text()"), 'é');
  });
  test(
    'replacing a file keeps its write charge and replaces its memory charge',
    () async {
      await h.run(w, "Path('a').write_text('abc')\nPath('a').write_text('x')");
      expect(w.memoryUsage, 129);
      expect(w.writeBytes, 4);
    },
  );
  test('appending files adds a memory charge', () async {
    await h.run(
      w,
      "Path('a').write_text('ab')\nf = open('a', 'a')\nf.write('é')\nf.close()",
    );
    expect(w.writeBytes, 4);
    expect(w.memoryUsage, 132);
  });
  test('opening a file for writing retains its write charge', () async {
    await h.run(w, "Path('a').write_text('ab')\nopen('a', 'w').close()");
    expect(w.memoryUsage, 128);
    expect(w.writeBytes, 2);
  });
  test(
    'opening a file for appending charges memory but no written bytes',
    () async {
      await h.run(w, "open('a', 'a').close()\nopen('a', 'a').close()");
      expect(w.memoryUsage, 128);
      expect(w.writeBytes, 0);
    },
  );
  test('creating parent directories uses memory', () async {
    await h.run(
      w,
      "Path('d/e').mkdir(parents=True)\n"
      "Path('d/e').mkdir(parents=True, exist_ok=True)",
    );
    expect(w.memoryUsage, 192);
  });
  test('write charges last for the workspace lifetime', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), writeBytesLimit: 3);
    await h.run(w, "Path('a').write_text('ab')\nPath('a').unlink()");
    expect(
      await h.caught(w, "Path('a').write_text('cd')"),
      'OSError: Workspace write byte limit exceeded',
    );
    expect(w.writeBytes, 2);
    expect(w.memoryUsage, 64);
  });
  test('memory limits are owned by the workspace', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), memoryUsageLimit: 128);
    expect(
      await h.caught(w, "Path('a').write_text('x')"),
      'MemoryError: Workspace memory limit exceeded',
    );
    final core = OSAccess();
    expect(
      await h.session.feedRun(
        "from pathlib import Path\nPath('/a').write_text('x')",
        os: core.call,
      ),
      const MontyInt(1),
    );
  });
  test('write limits reject excess writes', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), writeBytesLimit: 2);
    await h.run(w, "Path('a').write_text('ab')");
    await h.caught(w, "Path('a').write_text('c')");
    expect(await h.run(w, "Path('a').read_text()"), 'ab');
    expect(w.writeBytes, 2);
    expect(w.memoryUsage, 130);
  });
  test('a failed operation charges no write bytes', () async {
    expect(
      await h.caught(w, "Path('absent/a').write_text('x')"),
      startsWith('FileNotFoundError:'),
    );
    expect(w.writeBytes, 0);
    expect(w.memoryUsage, 64);
    await h.run(w, "Path('a').write_text('x')");
    expect(w.writeBytes, 1);
  });
  test('write limits apply across feed boundaries', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), writeBytesLimit: 3);
    await h.run(w, "Path('a').write_text('ab')");
    expect(
      await h.caught(w, "Path('a').write_text('cd')"),
      startsWith('OSError:'),
    );
    expect(w.writeBytes, 2);
  });
  test('read-only files reject writes without changing charges', () async {
    w = Workspace(
      sandboxBaseDir: backing?.call(),
      files: {'ro/a': 'x'},
      readOnly: {'ro'},
    );
    expect(await h.run(w, "Path('ro/a').read_text()"), 'x');
    for (final code in [
      "Path('ro/a').write_text('z')",
      "open('ro/a', 'a')",
      "open('ro/a', 'w')",
      "Path('ro/a').unlink()",
      "Path('ro/b').mkdir()",
      "Path('ro').rmdir()",
      "Path('ro').rename('new')",
      "Path('ro/a').rename('new')",
    ]) {
      expect(
        await h.caught(w, code),
        startsWith('PermissionError: [Errno 30] Read-only file system:'),
      );
    }
    expect(w.writeBytes, 0);
    expect(w.memoryUsage, 193);
  });
  test('text and byte writes use their encoded sizes', () async {
    await h.run(w, "Path('t').write_text('😀')\nPath('b').write_bytes(b'xy')");
    expect(w.writeBytes, 6);
    expect(w.memoryUsage, 198);
  });
  test('seeded files can be overwritten within limits', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), files: {'a': 'seed'});
    await h.run(w, "Path('a').write_text('é')");
    expect(w.memoryUsage, 130);
    expect(w.writeBytes, 2);
  });
  test(
    'a zero write budget still reports permission and missing-file errors',
    () async {
      w = Workspace(
        sandboxBaseDir: backing?.call(),
        files: {'ro': 'x'},
        readOnly: {'ro'},
        writeBytesLimit: 0,
      );
      expect(
        await h.caught(w, "Path('ro').write_text('x')"),
        startsWith('PermissionError:'),
      );
      expect(
        await h.caught(w, "Path('missing').unlink()"),
        startsWith('FileNotFoundError:'),
      );
      expect(w.writeBytes, 0);
    },
  );
  test('accepted and rejected writes keep distinct charges', () async {
    w = Workspace(sandboxBaseDir: backing?.call(), memoryUsageLimit: 194);
    await h.run(
      w,
      "Path('a').write_text('x')\nPath('b').write_text('y')\n"
      "Path('a').rename('b')",
    );
    expect(w.memoryUsage, 129);
    expect(w.writeBytes, 2);
    expect(await h.run(w, "Path('b').read_text()"), 'x');
    await h.caught(w, "Path('c').write_text('long')");
    expect(w.memoryUsage, 129);
    expect(w.writeBytes, 2);
  });
  test('workspace limits apply for each workspace lifetime', () async {
    final other = Workspace(
      sandboxBaseDir: backing?.call(),
      writeBytesLimit: 1,
    );
    addTearDown(other.dispose);
    await h.run(w, "Path('a').write_text('ab')");
    await h.run(other, "Path('a').write_text('x')");
    expect(other.writeBytes, 1);
    expect(w.writeBytes, 2);
    await w.dispose();
    expect(w.memoryUsage, 0);
    expect(
      () => w.call('Path.exists', [MontyPath('/work/a')], {}),
      throwsStateError,
    );
  });
}
