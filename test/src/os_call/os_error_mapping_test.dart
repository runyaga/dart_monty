// The write family leaked dart:io from BOTH handlers.
//
// Audited by driving every PathOp against a failing condition. Nine of ten
// read/delete/list operations already mapped their failures to
// OsCallException; the write family mapped none — in fsHandler AND in the
// sandboxed handler:
//
//     write_text  write_bytes  append_text  append_bytes
//
// all raising a raw FileSystemException when the target is a directory, where
// CPython raises IsADirectoryError. Python saw a Dart error.
//
// The fix maps at the HANDLER BOUNDARY rather than per-operation: one
// implementation instead of eight, and an operation added later is covered
// without anyone remembering to wrap it. These cases pin that both handlers
// route through it, and that the happy paths still return what they returned.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:file/local.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String rootPath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('monty_errmap_');
    rootPath = root.resolveSymbolicLinksSync();
    Directory('$rootPath/adir').createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  for (final handlerName in ['fsHandler', 'sandboxed']) {
    OsCallHandler build() => handlerName == 'fsHandler'
        ? fsHandler(const LocalFileSystem())
        : sandboxedFsHandler(root: root);

    group('$handlerName maps write failures', () {
      for (final op in [
        'Path.write_text',
        'Path.write_bytes',
        'Path.append_text',
        'Path.append_bytes',
      ]) {
        test('$op onto a directory is IsADirectoryError', () async {
          final payload = op.endsWith('bytes') ? [1, 2] : 'x';

          await expectLater(
            build()(op, ['$rootPath/adir', payload], null),
            throwsA(
              isA<OsCallException>()
                  .having(
                    (e) => e.pythonExceptionType,
                    'pythonExceptionType',
                    'IsADirectoryError',
                  )
                  // A real errno, not an un-interpolated template.
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      matches(RegExp(r'\[Errno \d+\]')),
                      isNot(contains(r'${')),
                    ),
                  ),
            ),
          );
        });
      }

      test('the happy path is unchanged', () async {
        final h = build();

        expect(
          await h('Path.write_text', ['$rootPath/f.txt', 'hello'], null),
          5,
          reason: 'write_text returns the codepoint count',
        );
        expect(
          await h('Path.append_text', ['$rootPath/f.txt', '!'], null),
          1,
        );
        expect(await h('Path.read_text', ['$rootPath/f.txt'], null), 'hello!');
      });

      test(
        'an existing typed refusal is NOT swallowed by the boundary',
        () async {
          // The boundary catches FileSystemException only. A handler that
          // caught everything would convert these into the generic mapping and
          // lose the specific type each arm already chose.
          await expectLater(
            build()('Path.read_text', ['$rootPath/ghost.txt'], null),
            throwsA(
              isA<OsCallException>().having(
                (e) => e.pythonExceptionType,
                'pythonExceptionType',
                'FileNotFoundError',
              ),
            ),
          );
        },
      );
    });
  }
}
