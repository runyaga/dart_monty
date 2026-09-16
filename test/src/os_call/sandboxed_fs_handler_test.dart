// Tests for sandboxedFsHandler behavior NOT covered by the shared
// contract.
//
// The shared FS handler contract
// (run via sandboxed_fs_handler_contract_test.dart) covers:
//   - File CRUD: write/read text & bytes round-trips, return types
//   - Directory: mkdir (with parents, exist_ok), iterdir, rmdir
//   - Queries: exists, is_file, is_dir
//   - Mutations: unlink, rename
//   - Path ops: resolve, absolute
//
// This file tests only:
//   - Security boundary enforcement (path traversal, symlink
//     escape, prefix-collision, write/rename outside sandbox)
//   - Path normalization (redundant separators)

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
    root = Directory.systemTemp.createTempSync('monty_sandbox_test_');
    // Resolve symlinks so paths match on macOS (/var -> /private/var).
    rootPath = root.resolveSymbolicLinksSync();
    handler = sandboxedFsHandler(root: root);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  group('sandboxedFsHandler', () {
    // -- Security tests --

    group('security', () {
      test('path traversal via ../ is rejected', () {
        expect(
          () => handler('Path.read_text', [
            '$rootPath/../../../etc/passwd',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('path traversal via /../ in middle is rejected', () {
        expect(
          () => handler('Path.read_text', [
            '$rootPath/sub/../../etc/passwd',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('absolute path outside root is rejected', () {
        expect(
          () => handler('Path.read_text', ['/etc/passwd'], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('path that startsWith root prefix but is different dir is '
          'rejected', () {
        // e.g., root=/tmp/sandbox, path=/tmp/sandboxevil/etc/passwd
        // This is the exact edge case from review comment #9.
        final evilDir = Directory('${rootPath}evil')..createSync();
        addTearDown(() {
          if (evilDir.existsSync()) evilDir.deleteSync(recursive: true);
        });

        File('${evilDir.path}/secret.txt').writeAsStringSync('stolen');

        expect(
          () => handler('Path.read_text', [
            '${rootPath}evil/secret.txt',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('symlink inside sandbox pointing outside is rejected', () {
        // Create a symlink inside the sandbox that points to /tmp.
        final link = Link('$rootPath/escape_link')..createSync('/tmp');

        expect(link.existsSync(), isTrue);

        expect(
          () => handler('Path.read_text', [
            '$rootPath/escape_link',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      // THE WRITE OPS WERE NEVER COVERED. Both symlink tests above drive
      // `Path.read_text`, and read_text was already one of the four ops that
      // resolved symlinks. Every CONTENT-CREATING op -- open, write_text,
      // write_bytes, append_text, append_bytes, mkdir, rmdir -- used lexical
      // containment only, so a symlink inside the root let a write land
      // outside it. Measured before the fix:
      //
      //   write_text escape/pwned.txt -> NO EXCEPTION, file written OUTSIDE
      //   mkdir      escape/newdir    -> NO EXCEPTION
      //
      // These tests are the ones that would have caught it.
      for (final op in const [
        'Path.write_text',
        'Path.write_bytes',
        'Path.append_text',
        'Path.mkdir',
      ]) {
        test('$op THROUGH a symlink escaping the sandbox is rejected', () {
          final outsideDir = Directory.systemTemp.createTempSync(
            'monty_outside_w_',
          );
          addTearDown(() => outsideDir.deleteSync(recursive: true));
          Link('$rootPath/w_link').createSync(outsideDir.path);

          final args = <Object?>[
            '$rootPath/w_link/victim.txt',
            if (op == 'Path.write_bytes')
              <int>[1, 2, 3]
            else if (op != 'Path.mkdir')
              'ESCAPED',
          ];

          expect(
            () => handler(op, args, null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.pythonExceptionType,
                'pythonExceptionType',
                'PermissionError',
              ),
            ),
            reason:
                '$op must not write through a symlink that leaves the sandbox',
          );
          expect(
            File('${outsideDir.path}/victim.txt').existsSync(),
            isFalse,
            reason: 'nothing may be created outside the sandbox root',
          );
        });
      }

      test('creating a NEW entry under a symlinked parent is rejected', () {
        // The case the old guard missed ENTIRELY: it resolved only when the
        // path already existed, so a not-yet-created file under a symlinked
        // directory took the lexical branch and escaped.
        final outsideDir = Directory.systemTemp.createTempSync(
          'monty_outside_n_',
        );
        addTearDown(() => outsideDir.deleteSync(recursive: true));
        Link('$rootPath/new_link').createSync(outsideDir.path);

        expect(
          () => handler('Path.write_text', [
            '$rootPath/new_link/brand_new.txt',
            'ESCAPED',
          ], null),
          throwsA(isA<OsCallException>()),
        );
        expect(File('${outsideDir.path}/brand_new.txt').existsSync(), isFalse);
      });

      test('unlink removes the LINK, not what it points at', () async {
        // CPython's Path.unlink() removes the link entry and leaves the target.
        // This handler resolved first and deleted the TARGET, leaving a
        // dangling link -- inverted, and data loss for anyone removing an
        // alias. Both paths are inside the root, so this tests unlink's
        // semantics rather than its containment guard.
        final target = File('$rootPath/real.txt')..writeAsStringSync('KEEP ME');
        Link('$rootPath/alias').createSync(target.path);

        await handler('Path.unlink', ['$rootPath/alias'], null);

        expect(
          target.existsSync(),
          isTrue,
          reason: 'unlink must not delete the symlink target',
        );
        expect(
          Link('$rootPath/alias').existsSync(),
          isFalse,
          reason: 'unlink must remove the link entry itself',
        );
      });

      test(
        'unlink through a symlink leaving the sandbox is still rejected',
        () {
          // Containment must survive the semantics change above.
          final outsideDir = Directory.systemTemp.createTempSync(
            'monty_outside_u_',
          );
          addTearDown(() => outsideDir.deleteSync(recursive: true));
          final victim = File('${outsideDir.path}/victim.txt')
            ..writeAsStringSync('do not delete');
          Link('$rootPath/u_link').createSync(victim.path);

          expect(
            () => handler('Path.unlink', ['$rootPath/u_link'], null),
            throwsA(isA<OsCallException>()),
          );
          expect(victim.existsSync(), isTrue);
        },
      );

      test('rmdir on a symlink raises NotADirectoryError, deletes nothing', () {
        // Same resolve-then-act shape as unlink. CPython raises
        // NotADirectoryError for rmdir on a symlink even when it points at a
        // directory -- the link is not itself a directory. Before the fix this
        // followed the link and removed the REAL directory.
        //
        // realdir is EMPTY on purpose: leaving a file in it makes the delete
        // fail with "directory not empty", which masks the bug behind what
        // looks like a correct refusal.
        final real = Directory('$rootPath/realdir')..createSync();
        Link('$rootPath/dirlink').createSync(real.path);

        expect(
          () => handler('Path.rmdir', ['$rootPath/dirlink'], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'NotADirectoryError',
            ),
          ),
        );
        expect(
          real.existsSync(),
          isTrue,
          reason: 'rmdir on a link must not remove the directory it points at',
        );
      });

      test('rmdir still removes an ordinary empty directory', () async {
        // The other direction: the guard above must not break real rmdir.
        final d = Directory('$rootPath/plaindir')..createSync();
        await handler('Path.rmdir', ['$rootPath/plaindir'], null);
        expect(d.existsSync(), isFalse);
      });

      test(
        'write_text/append_text return CODEPOINTS, not UTF-16 units',
        () async {
          // CPython's Path.write_text() returns the number of CHARACTERS.
          // Dart's String.length is UTF-16 code units, so anything outside the
          // BMP counts twice. The two agree for ASCII, which is why this hid.
          // dart_monty_core fixed the same bug and documents it at
          // memory_mounted_os_handler.dart:730 (_codepointCount).
          const text = 'hi \u{1F600}!'; // 'hi ' + emoji + '!'
          expect(text.length, 6, reason: 'UTF-16 code units');
          expect(text.runes.length, 5, reason: "what CPython's len() returns");

          final written = await handler('Path.write_text', [
            '$rootPath/emoji.txt',
            text,
          ], null);
          expect(written, 5, reason: 'write_text must count codepoints');

          final appended = await handler('Path.append_text', [
            '$rootPath/emoji.txt',
            text,
          ], null);
          expect(appended, 5, reason: 'append_text must count codepoints');
        },
      );

      test('ordinary writes inside the sandbox still succeed', () async {
        // The other direction: hardening the guard must not break legitimate
        // use. A fix that rejects everything would pass the tests above.
        await handler('Path.mkdir', ['$rootPath/sub'], null);
        await handler('Path.write_text', ['$rootPath/sub/ok.txt', 'hi'], null);
        expect(File('$rootPath/sub/ok.txt').readAsStringSync(), 'hi');
      });

      test('symlink chain escaping sandbox is rejected', () {
        // Create a file outside the sandbox.
        final outsideDir = Directory.systemTemp.createTempSync(
          'monty_outside_',
        );
        addTearDown(() => outsideDir.deleteSync(recursive: true));

        File('${outsideDir.path}/secret.txt').writeAsStringSync('stolen');

        // Symlink inside sandbox -> outside file.
        Link(
          '$rootPath/chain_link',
        ).createSync('${outsideDir.path}/secret.txt');

        expect(
          () => handler('Path.read_text', [
            '$rootPath/chain_link',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('Path.resolve on symlink outside sandbox is rejected', () {
        final outsideDir = Directory.systemTemp.createTempSync(
          'monty_resolve_',
        );
        addTearDown(() => outsideDir.deleteSync(recursive: true));

        Link('$rootPath/resolve_link').createSync(outsideDir.path);

        expect(
          () => handler('Path.resolve', [
            '$rootPath/resolve_link',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('normalize removes redundant separators', () async {
        File('$rootPath/norm.txt').writeAsStringSync('ok');

        // Double slashes should normalize and still work.
        final result = await handler('Path.read_text', [
          '$rootPath//norm.txt',
        ], null);

        expect(result, 'ok');
      });

      test('write to path outside sandbox is rejected', () {
        expect(
          () => handler('Path.write_text', [
            '/tmp/escape.txt',
            'pwned',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });

      test('rename target outside sandbox is rejected', () {
        File('$rootPath/src.txt').writeAsStringSync('data');

        expect(
          () => handler('Path.rename', [
            '$rootPath/src.txt',
            '/tmp/escaped.txt',
          ], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      });
    });
  });
}
