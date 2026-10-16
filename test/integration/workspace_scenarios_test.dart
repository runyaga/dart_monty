// Child programs intentionally contain complete filesystem scenarios.
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  late MontyRuntime runtime;

  setUp(() async {
    runtime = await MontyRuntime.start(
      pool: await childContractPool(),
      os: OSAccess().call,
      extensions: [SandboxExtension()],
    );
  });
  tearDown(() => runtime.dispose());

  Future<Object?> run(String code) async =>
      (await runtime.execute(code).result).dartValue;

  group('child workspace scenarios', () {
    test('child workspace is empty and isolated by default', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
h = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[caught(lambda: Path('/work/a.txt').read_text()), Path('/work/a.txt').exists(), Path('/work').is_dir(), sorted(str(p) for p in Path('/work').iterdir())]''')
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [
          "FileNotFoundError: [Errno 2] No such file or directory: '/work/a.txt'",
          false,
          true,
          <Object?>[],
        ],
      );
    });

    test('child cannot access paths outside its workspace', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
h = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[caught(lambda: Path('/data/a.txt').read_text()), caught(lambda: Path('/data/a.txt').exists())]''')
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        // dm reports every outside-workspace filesystem operation as denied.
        [
          "PermissionError: Permission denied: '/data/a.txt'",
          "PermissionError: Permission denied: '/data/a.txt'",
        ],
      );
    });

    test('copy-in file changes stay in the child', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
h = sandbox_spawn(code=r'''from pathlib import Path
r = Path('/work/a.txt').read_text()
Path('/work/a.txt').write_text('CHILD')
[r, Path('/work/a.txt').read_text()]''', files={'a.txt': '/data/a.txt'})
observed = [sandbox_await(handle=h), Path('/data/a.txt').read_text()]
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [
          ['A', 'CHILD'],
          'A',
        ],
      );
    });

    test('selected child output copies back to the parent', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
h = sandbox_spawn(code=r'''from pathlib import Path
Path('/work/out.txt').write_text('OUT')
Path('/work/tmp.txt').write_text('TMP')
'done' ''')
observed = [sandbox_await(handle=h, collect={'out.txt': '/data/out.txt'}), Path('/data/out.txt').read_text(), Path('/data/tmp.txt').exists()]
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        ['done', 'OUT', false],
      );
    });

    test('directory inputs preserve their tree', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data/d/sub').mkdir(parents=True)
Path('/data/d/x.txt').write_text('X')
Path('/data/d/sub/y.txt').write_text('Y')
h = sandbox_spawn(code=r'''from pathlib import Path
def walk(p):
    out = []
    for q in p.iterdir():
        if q.is_dir():
            out.extend(walk(q))
        else:
            out.append((str(q), q.read_text()))
    return out
sorted(walk(Path('/work/d')))''', files={'d': '/data/d'})
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [
          ['/work/d/sub/y.txt', 'Y'],
          ['/work/d/x.txt', 'X'],
        ],
      );
    });

    test('parallel children keep separate output workspaces', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
h1 = sandbox_spawn(code=r'''from pathlib import Path
Path('/work/out.txt').write_text('one')
1''')
h2 = sandbox_spawn(code=r'''from pathlib import Path
Path('/work/out.txt').write_text('two')
2''')
rows = sandbox_gather(handles=[h1, h2])
sandbox_await(handle=h1, collect={'out.txt': '/data/r1.txt'})
sandbox_await(handle=h2, collect={'out.txt': '/data/r2.txt'})
observed = [[row['value'] for row in rows], Path('/data/r1.txt').read_text(), Path('/data/r2.txt').read_text()]
assert sandbox_is_alive(handle=h1) is False
assert sandbox_is_alive(handle=h2) is False
sandbox_free(handle=h1)
sandbox_free(handle=h2)
observed
"""),
        [
          [1, 2],
          'one',
          'two',
        ],
      );
    });

    test('workspace write limit applies cumulatively', () async {
      expect(
        await run("""
h = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[caught(lambda: Path('/work/a.txt').write_text('12345')), caught(lambda: Path('/work/b.txt').write_text('12345')), caught(lambda: Path('/work/c.txt').write_text('1'))]''', write_bytes_limit=10)
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [5, 5, 'OSError: Workspace write byte limit exceeded'],
      );
    });

    test('workspace memory limit rejects oversized content', () async {
      expect(
        await run("""
h = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[caught(lambda: Path('/work/big.txt').write_text('x' * 2000))]''', memory_usage_limit=1000)
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        ['MemoryError: Workspace memory limit exceeded'],
      );
    });

    test('child starts in the work directory', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
h = sandbox_spawn(code=r'''from pathlib import Path
import os
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[os.getcwd(), open('a.txt').read(), caught(lambda: Path('rel').mkdir()), caught(lambda: Path('rel/b.txt').write_text('B')), Path('/work/rel/b.txt').read_text(), str(Path('a.txt').resolve())]''', files={'a.txt': '/data/a.txt'})
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        ['/work', 'A', null, 1, 'B', '/work/a.txt'],
      );
    });

    test('read-only inputs reject file and directory writes', () async {
      // dm mounts read-only inputs beneath /work because child paths are relative.
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
h = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
[Path('/work/in/a.txt').read_text(), caught(lambda: Path('/work/in/a.txt').write_text('x')), caught(lambda: Path('/work/in/new.txt').write_text('x'))]''', ro_files={'in': '/data'})
observed = sandbox_await(handle=h)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [
          'A',
          "PermissionError: [Errno 30] Read-only file system: '/work/in/a.txt'",
          "PermissionError: [Errno 30] Read-only file system: '/work/in/new.txt'",
        ],
      );
    });

    test('failed children do not collect partial output', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
h = sandbox_spawn(code=r'''from pathlib import Path
Path('/work/out.txt').write_text('partial')
raise ValueError('boom')''')
try:
    observed = sandbox_await(handle=h, collect={'out.txt': '/data/out.txt'})
except Exception as e:
    observed = type(e).__name__ + ': ' + str(e)
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
[observed, Path('/data/out.txt').exists()]
"""),
        [
          'RuntimeError: ChildSandboxException(child 0): ValueError: boom',
          false,
        ],
      );
    });

    test('parent state persists across feeds', () async {
      expect(
        await run("""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/a.txt').write_text('A')
'fed1'
"""),
        'fed1',
      );
      expect(
        await run(r"""
from pathlib import Path
h = sandbox_spawn(code="from pathlib import Path\nPath('/work/a.txt').read_text()", files={'a.txt': '/data/a.txt'})
observed = [sandbox_await(handle=h), Path('/data/a.txt').read_text()]
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        ['A', 'A'],
      );
    });

    test('binary files round-trip without change', () async {
      expect(
        await run(r"""
from pathlib import Path
Path('/data').mkdir(exist_ok=True)
Path('/data/b.bin').write_bytes(b'\x00\xff')
h = sandbox_spawn(code=r'''from pathlib import Path
f = open('/work/b.bin', 'ab')
f.write(b'\x01')
f.close()
Path('/work/b.bin').read_bytes()''', files={'b.bin': '/data/b.bin'})
observed = [sandbox_await(handle=h, collect={'b.bin': '/data/b2.bin'}), Path('/data/b2.bin').read_bytes(), Path('/data/b.bin').read_bytes()]
assert sandbox_is_alive(handle=h) is False
sandbox_free(handle=h)
observed
"""),
        [
          Uint8List.fromList([0, 255, 1]),
          Uint8List.fromList([0, 255, 1]),
          Uint8List.fromList([0, 255]),
        ],
      );
    });

    test('workspace limits are independent per child', () async {
      expect(
        await run("""
h1 = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
caught(lambda: Path('/work/a.txt').write_text('12345678'))''', write_bytes_limit=10)
h2 = sandbox_spawn(code=r'''from pathlib import Path
def caught(f):
    try:
        return f()
    except Exception as e:
        return type(e).__name__ + ': ' + str(e)
caught(lambda: Path('/work/a.txt').write_text('12345678'))''', write_bytes_limit=10)
rows = sandbox_gather(handles=[h1, h2])
observed = [row['value'] for row in rows]
assert sandbox_is_alive(handle=h1) is False
assert sandbox_is_alive(handle=h2) is False
sandbox_free(handle=h1)
sandbox_free(handle=h2)
observed
"""),
        [8, 8],
      );
    });
  });
}
