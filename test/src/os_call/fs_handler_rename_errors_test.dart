// fsHandler's rename mapped no OS error at all.
//
// `PathOp.rename` was four lines: resolve both paths, `renameSync`, return.
// Every failure escaped as a raw dart:io FileSystemException, so Python saw a
// Dart error rather than an OSError. `iterdir`, twelve lines below in the same
// switch, has always mapped its failure to FileNotFoundError — rename never
// did.
//
// Found by asking whether the symlink-destination leak fixed in the SANDBOXED
// handler (ab2c212) existed elsewhere. It did, and wider: not just symlink
// destinations but every failure mode.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/local.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String rootPath;
  late OsCallHandler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('monty_fsh_rename_');
    rootPath = root.resolveSymbolicLinksSync();
    handler = fsHandler(const LocalFileSystem());
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The message must carry the REAL errno and the REAL paths.
  ///
  /// `contains('Errno')` alone is not enough: an interpolation that got
  /// escaped would emit the literal text `[Errno ${os?.errorCode}]` and still
  /// contain the word. That happened while writing this — the string was
  /// mangled to `\${...}`, every case here passed, and the message was
  /// useless. So match a DIGIT after Errno, and the paths.
  Matcher throwsOsCall(String type, {String? pathFragment}) => throwsA(
    isA<OsCallException>()
        .having((e) => e.pythonExceptionType, 'pythonExceptionType', type)
        .having(
          (e) => e.message,
          'message',
          allOf(
            matches(RegExp(r'\[Errno \d+\]')),
            contains(pathFragment ?? rootPath),
            isNot(contains(r'${')),
          ),
        ),
  );

  test(
    'a missing source is FileNotFoundError, not FileSystemException',
    () async {
      await expectLater(
        handler('Path.rename', ['$rootPath/ghost', '$rootPath/x'], null),
        throwsOsCall('FileNotFoundError'),
      );
    },
  );

  test('renaming onto a directory is IsADirectoryError', () async {
    Directory('$rootPath/d').createSync();
    File('$rootPath/f.txt').writeAsStringSync('x');

    await expectLater(
      handler('Path.rename', ['$rootPath/f.txt', '$rootPath/d'], null),
      throwsOsCall('IsADirectoryError'),
    );
    // The refusal must not have half-executed.
    expect(File('$rootPath/f.txt').readAsStringSync(), 'x');
    expect(Directory('$rootPath/d').existsSync(), isTrue);
  });

  test('renaming onto a SYMLINK no longer leaks dart:io', () async {
    // The case that started this: ab2c212 fixed it in the sandboxed handler,
    // and the same call through fsHandler still leaked.
    Directory('$rootPath/target').createSync();
    Link('$rootPath/alias').createSync('$rootPath/target');
    Directory('$rootPath/src').createSync();

    await expectLater(
      handler('Path.rename', ['$rootPath/src', '$rootPath/alias'], null),
      throwsA(isA<OsCallException>()),
    );
    expect(
      FileSystemEntity.typeSync('$rootPath/alias', followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('a successful rename still returns the new path', () async {
    File('$rootPath/a.txt').writeAsStringSync('content');

    final r = await handler(
      'Path.rename',
      ['$rootPath/a.txt', '$rootPath/b.txt'],
      null,
    );

    expect(r, '$rootPath/b.txt');
    expect(File('$rootPath/b.txt').readAsStringSync(), 'content');
    expect(File('$rootPath/a.txt').existsSync(), isFalse);
  });
}
