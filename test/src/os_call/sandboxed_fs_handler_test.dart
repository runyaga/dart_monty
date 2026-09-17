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
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyPath, OsCallNotHandledException;
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

      test('resolve/absolute return MontyPath, not a bare String', () async {
        // CPython's resolve()/absolute() return pathlib.Path. A bare String
        // gives Python a `str`, so `.name` / `.parent` / `.suffix` on the
        // result raise AttributeError. dart_monty_core records hitting exactly
        // this at memory_mounted_os_handler.dart:461-470. `iterdir` in the same
        // switch already returned MontyPath; these two did not.
        File('$rootPath/f.txt').writeAsStringSync('x');

        expect(
          await handler('Path.resolve', ['$rootPath/f.txt'], null),
          isA<MontyPath>(),
        );
        expect(
          await handler('Path.absolute', ['$rootPath/f.txt'], null),
          isA<MontyPath>(),
        );
      });

      test('an unknown op DECLINES, it does not throw UnsupportedError', () {
        // composeOsHandlers treats OsCallNotHandledException as "not mine", so
        // a sibling handler -- or the call's documented default -- can answer.
        // Throwing UnsupportedError defeated that twice: no sibling got the
        // chance, and the Dart type name leaked into the sandbox as
        //   RuntimeError: Unsupported operation: Unsupported path
        //   operation: ...
        expect(
          () => handler('Path.stat', ['$rootPath/any.txt'], null),
          throwsA(isA<OsCallNotHandledException>()),
          reason: 'unknown ops must decline so composition still works',
        );
      });

      group("rename follows CPython's outcome matrix", () {
        // Was `File(old).renameSync(new)` -- four lines that always treated
        // the source as a FILE. Renaming a DIRECTORY failed outright, and
        // every error arrived as a bare RuntimeError carrying a Dart message.
        // dart_monty_core implements the same matrix and cites the fixtures
        // that assert each message (memory_mounted_os_handler.dart:594-605).

        test('missing source -> FileNotFoundError', () {
          expect(
            () => handler('Path.rename', [
              '$rootPath/nope.txt',
              '$rootPath/b.txt',
            ], null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.pythonExceptionType,
                'type',
                'FileNotFoundError',
              ),
            ),
          );
        });

        test('file -> existing file overwrites SILENTLY', () async {
          File('$rootPath/s.txt').writeAsStringSync('new');
          File('$rootPath/t.txt').writeAsStringSync('old');
          await handler('Path.rename', [
            '$rootPath/s.txt',
            '$rootPath/t.txt',
          ], null);
          expect(File('$rootPath/t.txt').readAsStringSync(), 'new');
          expect(File('$rootPath/s.txt').existsSync(), isFalse);
        });

        test('file -> directory raises IsADirectoryError', () {
          File('$rootPath/s2.txt').writeAsStringSync('x');
          Directory('$rootPath/d2').createSync();
          expect(
            () => handler('Path.rename', [
              '$rootPath/s2.txt',
              '$rootPath/d2',
            ], null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.pythonExceptionType,
                'type',
                'IsADirectoryError',
              ),
            ),
          );
        });

        test(
          'directory -> missing MOVES (this used to fail outright)',
          () async {
            Directory('$rootPath/sd').createSync();
            File('$rootPath/sd/inner.txt').writeAsStringSync('keep');
            await handler('Path.rename', [
              '$rootPath/sd',
              '$rootPath/dd',
            ], null);
            expect(Directory('$rootPath/dd').existsSync(), isTrue);
            expect(File('$rootPath/dd/inner.txt').readAsStringSync(), 'keep');
          },
        );

        test('directory -> file raises NotADirectoryError', () {
          Directory('$rootPath/sd2').createSync();
          File('$rootPath/f2.txt').writeAsStringSync('x');
          expect(
            () => handler('Path.rename', [
              '$rootPath/sd2',
              '$rootPath/f2.txt',
            ], null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.pythonExceptionType,
                'type',
                'NotADirectoryError',
              ),
            ),
          );
        });

        test('directory -> NON-EMPTY directory raises [Errno 39]', () {
          Directory('$rootPath/sd3').createSync();
          Directory('$rootPath/dd3').createSync();
          File('$rootPath/dd3/occupied.txt').writeAsStringSync('x');
          expect(
            () => handler('Path.rename', [
              '$rootPath/sd3',
              '$rootPath/dd3',
            ], null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.message,
                'message',
                contains('Errno 39'),
              ),
            ),
          );
        });

        test(
          'self-rename of an EMPTY directory is a NO-OP, not deletion',
          () async {
            // POSIX: if both names refer to the same existing entry, rename
            // succeeds and changes nothing. The first version of the matrix
            // treated the destination as a distinct empty directory, deleted it
            // -- which IS the source -- and then failed to move it. Measured:
            // `dir still exists? false`. Data loss, worse than the four-line
            // implementation it replaced.
            Directory('$rootPath/same').createSync();
            await handler('Path.rename', [
              '$rootPath/same',
              '$rootPath/same',
            ], null);
            expect(Directory('$rootPath/same').existsSync(), isTrue);
          },
        );

        test('query ops do not see through a symlink out of the root', () {
          // exists / is_file / is_dir / iterdir used the LEXICAL safePath, so
          // with `escape` a symlink pointing out of the root the guest could
          // probe and ENUMERATE the host filesystem. Measured before the fix:
          //   exists escape/secret.txt -> true;  iterdir escape -> real names.
          // No op here creates a symlink, so this needs one already inside the
          // root -- which is what a mounted directory is.
          final outside = Directory.systemTemp.createTempSync('monty_out_q_');
          addTearDown(() => outside.deleteSync(recursive: true));
          File('${outside.path}/secret.txt').writeAsStringSync('TOPSECRET');
          Directory('${outside.path}/secretdir').createSync();
          Link('$rootPath/escape').createSync(outside.path);

          for (final op in ['Path.exists', 'Path.is_file', 'Path.is_dir']) {
            expect(
              () => handler(op, ['$rootPath/escape/secret.txt'], null),
              throwsA(isA<OsCallException>()),
              reason: '$op leaked through the symlink',
            );
          }
          expect(
            () => handler('Path.iterdir', ['$rootPath/escape'], null),
            throwsA(isA<OsCallException>()),
          );
          // The negative oracle is closed too: a NON-existent path outside
          // must refuse, not answer false.
          expect(
            () => handler('Path.exists', ['$rootPath/escape/nope.txt'], null),
            throwsA(isA<OsCallException>()),
          );
        });

        test('is_symlink still answers for a link INSIDE the root', () async {
          // The fix must not over-refuse. A symlink that lives in the sandbox
          // is a legitimate thing to ask about even when it points outside:
          // CPython says True and the link itself is contained. Containment is
          // checked on the PARENT, which is what gets traversed.
          final outside = Directory.systemTemp.createTempSync('monty_out_s_');
          addTearDown(() => outside.deleteSync(recursive: true));
          Link('$rootPath/mylink').createSync(outside.path);

          expect(
            await handler('Path.is_symlink', ['$rootPath/mylink'], null),
            isTrue,
          );
        });

        test('destination is symlink-checked, not lexical-only', () {
          // rename's DESTINATION used safePath (lexical only) while every
          // other write path used safeResolved. With `escape` a symlink out of
          // the root, `rename('src.txt', 'escape/leaked.txt')` moved the file
          // OUTSIDE the sandbox -- measured, "landed outside? true".
          final outside = Directory.systemTemp.createTempSync('monty_out_ren_');
          addTearDown(() => outside.deleteSync(recursive: true));
          Link('$rootPath/escape').createSync(outside.path);
          File('$rootPath/src.txt').writeAsStringSync('SECRET');

          expect(
            () => handler('Path.rename', [
              '$rootPath/src.txt',
              '$rootPath/escape/leaked.txt',
            ], null),
            throwsA(isA<OsCallException>()),
          );
          expect(File('${outside.path}/leaked.txt').existsSync(), isFalse);
        });

        test('directory -> EMPTY directory replaces it', () async {
          Directory('$rootPath/sd4').createSync();
          File('$rootPath/sd4/x.txt').writeAsStringSync('v');
          Directory('$rootPath/dd4').createSync();
          await handler('Path.rename', [
            '$rootPath/sd4',
            '$rootPath/dd4',
          ], null);
          expect(File('$rootPath/dd4/x.txt').readAsStringSync(), 'v');
        });
      });

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
