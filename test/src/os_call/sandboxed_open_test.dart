// The sandboxed handler's open(), appends, and relative-path resolution.
//
// lib/src/os_call/sandboxed_fs_handler.dart is 83.9% on MERGED unit +
// integration coverage, and the 26 lines neither suite reaches are not
// incidental:
//
//   :118-144  PathOp.open — all four callbacks (exists, isDirectory,
//             truncate, createIfMissing), each routing through
//             `safeResolved` for containment
//   :152-158  PathOp.appendBytes
//   :35       the RELATIVE-path branch of safeResolved — a bare `notes.txt`
//             joined against the root rather than the process CWD
//   :471-474  the rename helper's break arms, i.e. renaming a directory onto
//             a target that does not exist — the ordinary case
//
// `open()` is the widest door in this handler: it is the one operation that
// both reads and creates, and every one of its four callbacks resolves a path
// independently. An `open()` that skipped containment would escape the
// sandbox while `read_text` and `write_text` stayed sealed, and the existing
// suite — which tests those two thoroughly — would not notice.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String rootPath;
  late OsCallHandler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('monty_sandbox_open_');
    // Resolve symlinks or macOS /var -> /private/var breaks containment
    // comparisons before the code under test is reached.
    rootPath = root.resolveSymbolicLinksSync();
    handler = sandboxedFsHandler(root: root);
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('sandboxed open()', () {
    test('open for read succeeds on a file inside the root', () async {
      File('$rootPath/in.txt').writeAsStringSync('hello');

      await handler('open', ['$rootPath/in.txt', 'r'], null);

      expect(File('$rootPath/in.txt').readAsStringSync(), 'hello');
    });

    test("open 'w' CREATES the file inside the root", () async {
      await handler('open', ['$rootPath/made.txt', 'w'], null);

      expect(File('$rootPath/made.txt').existsSync(), isTrue);
    });

    test("open 'w' TRUNCATES an existing file", () async {
      File('$rootPath/full.txt').writeAsStringSync('previous contents');

      await handler('open', ['$rootPath/full.txt', 'w'], null);

      expect(File('$rootPath/full.txt').readAsStringSync(), isEmpty);
    });

    test("open 'a' does NOT truncate", () async {
      File('$rootPath/keep.txt').writeAsStringSync('kept');

      await handler('open', ['$rootPath/keep.txt', 'a'], null);

      expect(File('$rootPath/keep.txt').readAsStringSync(), 'kept');
    });

    test('open refuses a traversal escape', () {
      // The point of the whole file. Each callback resolves independently, so
      // containment has to hold in every one of them.
      expect(
        () => handler('open', ['$rootPath/../escape.txt', 'w'], null),
        throwsA(isA<OsCallException>()),
      );
      expect(
        File('${File(rootPath).parent.path}/escape.txt').existsSync(),
        isFalse,
      );
    });

    test('open refuses an absolute path outside the root', () {
      expect(
        () => handler('open', ['/etc/passwd', 'r'], null),
        throwsA(isA<OsCallException>()),
      );
    });
  });

  group('relative paths resolve against the ROOT, not the process CWD', () {
    test('a bare filename is created inside the sandbox', () async {
      // safeResolved:33-35. If a relative path were resolved against the
      // process working directory, this would write into the repository.
      await handler('Path.write_text', ['relative.txt', 'r'], null);

      expect(File('$rootPath/relative.txt').existsSync(), isTrue);
      expect(File('relative.txt').existsSync(), isFalse);
    });

    test('a relative path with .. still cannot escape', () {
      expect(
        () => handler('Path.write_text', ['../outside.txt', 'x'], null),
        throwsA(isA<OsCallException>()),
      );
    });
  });

  group('append operations', () {
    test('append_bytes appends and returns the byte count', () async {
      File('$rootPath/b.bin').writeAsBytesSync([1, 2]);

      final n = await handler('Path.append_bytes', [
        '$rootPath/b.bin',
        [3, 4, 5],
      ], null);

      expect(n, 3, reason: 'the return value is the count WRITTEN, not total');
      expect(File('$rootPath/b.bin').readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('append_bytes creates the file and its parent when missing', () async {
      final n = await handler('Path.append_bytes', [
        '$rootPath/nested/new.bin',
        [9],
      ], null);

      expect(n, 1);
      expect(File('$rootPath/nested/new.bin').readAsBytesSync(), [9]);
    });
  });

  group('directory rename onto a target that does not exist', () {
    test(
      'succeeds — the ordinary case, and the helper must allow it',
      () async {
        // _assertDirRenameTarget's notFound arm (the `break`). The suite covers
        // dir->file and dir->dir; renaming onto nothing was untested, which is
        // the case that must NOT raise.
        Directory('$rootPath/src').createSync();
        File('$rootPath/src/f.txt').writeAsStringSync('x');

        await handler('Path.rename', [
          '$rootPath/src',
          '$rootPath/dst',
        ], null);

        expect(Directory('$rootPath/src').existsSync(), isFalse);
        expect(File('$rootPath/dst/f.txt').readAsStringSync(), 'x');
      },
    );
  });
}
