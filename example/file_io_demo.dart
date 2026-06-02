// File I/O demo — open() / with open() and typed OS exceptions.
//
// monty v0.0.18 adds Python's `open()` with buffered read/write and
// `with open(...) as f:`. dart_monty routes the `Open` OS-call to whatever
// filesystem handler backs `Path.*` (here a sandboxed in-memory VFS), and core
// owns the open() mode→effect mapping — so file I/O "just works" through the
// same `osHandlers` wiring used for `pathlib.Path`.
//
// OS errors now reach Python as their real class, so scripts can
// `except FileNotFoundError:` / `except PermissionError:`.
//
// Run: dart run example/file_io_demo.dart

// Printing to stdout is expected in an example. The embedded Python source
// uses intentional `\\n` / `\\xNN` escapes (Dart-escaped so Python sees the
// real escape), so raw strings would corrupt them.
// ignore_for_file: avoid_print, use_raw_strings

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';

Future<void> main() async {
  // open() read/write/append + with open() ──────────────────────────────────
  final fs = MontyRuntime(osHandlers: {'Path.': memoryFsHandler()});

  await fs.execute('''
with open('/notes.txt', 'w') as f:
    f.write('line 1\\n')
    f.write('line 2\\n')
with open('/notes.txt', 'a') as f:
    f.write('appended\\n')
''').result;

  final read = await fs.execute('''
f = open('/notes.txt')
text = f.read()
f.close()
text
''').result;
  print('read back:\n${(read.value.dartValue! as String).trimRight()}');

  // Binary round-trip — package:file is byte-faithful ─────────────────────────
  final bin = await fs.execute('''
with open('/blob.bin', 'wb') as f:
    f.write(b'\\x00\\x01\\x02\\xff')
with open('/blob.bin', 'rb') as f:
    data = f.read()
list(data)
''').result;
  print('binary round-trip: ${bin.value.dartValue}'); // [0, 1, 2, 255]

  // The returned file object is a MontyFileHandle ─────────────────────────────
  final handle = await fs.execute("open('/notes.txt')").result;
  final v = handle.value;
  if (v is MontyFileHandle) {
    print('handle: path=${v.path} mode=${v.mode}');
  }

  // Typed FileNotFoundError, catchable in Python ──────────────────────────────
  final missing = await fs.execute('''
try:
    open('/nope.txt')
    out = 'no error'
except FileNotFoundError as e:
    out = f'caught {type(e).__name__}'
out
''').result;
  print('missing file: ${missing.value.dartValue}'); // caught FileNotFoundError

  await fs.dispose();

  // Typed PermissionError from a read-only handler ────────────────────────────
  final roFs = MemoryFileSystem();
  roFs.file('/secret.txt').writeAsStringSync('sk-1');
  final ro = MontyRuntime(osHandlers: {'Path.': fsHandler(roFs).readOnly()});
  final denied = await ro.execute('''
try:
    open('/secret.txt', 'w')
    out = 'no error'
except PermissionError:
    out = 'caught PermissionError'
out
''').result;
  print('read-only write: ${denied.value.dartValue}'); // caught PermissionError
  await ro.dispose();
}
