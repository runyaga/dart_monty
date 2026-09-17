// Renaming ONTO a symlink — containment at the destination.
//
// The sandbox resolves a rename's destination, so a symlink sitting inside the
// root that points OUTSIDE it is the obvious way to try to write past the
// boundary: create `root/alias -> /somewhere/else`, then rename a directory
// onto `alias`. If the destination were used unresolved, the move would land
// outside the sandbox.
//
// Measured: it is REFUSED, the outside target is untouched, and the link is
// left as a link. That is the behaviour this file pins — it is a property that
// nothing asserted, in the operation where this repo has already fixed one
// destination-resolution defect (the rename containment fix in 9f2c978).
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String rootPath;
  late Directory outside;
  late String outsidePath;
  late OsCallHandler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('monty_symlink_root_');
    rootPath = root.resolveSymbolicLinksSync();
    outside = Directory.systemTemp.createTempSync('monty_symlink_outside_');
    outsidePath = outside.resolveSymbolicLinksSync();
    handler = sandboxedFsHandler(root: root);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    if (outside.existsSync()) outside.deleteSync(recursive: true);
  });

  test('rename onto a symlink pointing OUTSIDE the root is refused', () async {
    File('$outsidePath/victim.txt').writeAsStringSync('ORIGINAL');
    Directory('$rootPath/src').createSync();
    File('$rootPath/src/payload.txt').writeAsStringSync('payload');
    Link('$rootPath/alias').createSync(outsidePath);

    await expectLater(
      handler('Path.rename', ['$rootPath/src', '$rootPath/alias'], null),
      throwsA(isA<OsCallException>()),
    );

    // The refusal has to be real, not just an exception: nothing outside may
    // have moved, been replaced, or been deleted.
    expect(
      File('$outsidePath/victim.txt').readAsStringSync(),
      'ORIGINAL',
      reason: 'the file outside the sandbox must be untouched',
    );
    expect(File('$outsidePath/payload.txt').existsSync(), isFalse);
    expect(
      FileSystemEntity.typeSync('$rootPath/alias', followLinks: false),
      FileSystemEntityType.link,
      reason: 'the link itself must survive — a replaced link is a moved dir',
    );
    expect(
      Directory('$rootPath/src').existsSync(),
      isTrue,
      reason: 'a refused rename must leave the source in place',
    );
  });

  test('rename onto an INTERNAL symlink raises NotADirectoryError', () async {
    // Containment PASSES here — the link points inside the root — so the
    // rename reaches the destination-type switch. Before this was fixed, the
    // link arm fell through to `Directory(...).renameSync(...)` and the OS
    // failure escaped as a RAW dart:io FileSystemException:
    //
    //     FileSystemException: Rename failed ... (OS Error: Not a directory,
    //     errno = 20)
    //
    // A raw FileSystemException past the OS-call boundary is the leak class
    // fs_handlers.dart:192 records ("same leak class as the bridge arm fixed
    // in 64fb4c8"): Python sees a Dart error instead of the OSError CPython
    // would raise for the same call.
    Directory('$rootPath/target').createSync();
    File('$rootPath/target/existing.txt').writeAsStringSync('TARGET');
    Link('$rootPath/alias_in').createSync('$rootPath/target');
    Directory('$rootPath/src').createSync();

    await expectLater(
      handler('Path.rename', ['$rootPath/src', '$rootPath/alias_in'], null),
      throwsA(
        isA<OsCallException>()
            .having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'NotADirectoryError',
            )
            .having((e) => e.message, 'message', contains('Errno 20')),
      ),
    );

    // os.rename does not follow the final symlink, so the link and its target
    // are both untouched.
    expect(
      FileSystemEntity.typeSync('$rootPath/alias_in', followLinks: false),
      FileSystemEntityType.link,
    );
    expect(File('$rootPath/target/existing.txt').readAsStringSync(), 'TARGET');
    expect(Directory('$rootPath/src').existsSync(), isTrue);
  });

  test(
    'the source survives, so a refused rename is not a silent delete',
    () async {
      Directory('$rootPath/src').createSync();
      File('$rootPath/src/keep.txt').writeAsStringSync('keep');
      Link('$rootPath/alias').createSync(outsidePath);

      await expectLater(
        handler('Path.rename', ['$rootPath/src', '$rootPath/alias'], null),
        throwsA(isA<OsCallException>()),
      );

      // The destructive failure mode for a rename is deleting the target first
      // and then failing to move. This asserts the source is still readable.
      expect(File('$rootPath/src/keep.txt').readAsStringSync(), 'keep');
    },
  );
}
