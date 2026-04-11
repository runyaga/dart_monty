import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty/src/bridge/os_call/sandboxed_fs_provider.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String rootPath;
  late SandboxedFsProvider handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('monty_sandbox_test_');
    // Resolve symlinks so paths match on macOS (/var -> /private/var).
    rootPath = root.resolveSymbolicLinksSync();
    handler = SandboxedFsProvider(root: root);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  MontyOsCall pathCall(
    String op,
    List<MontyValue> args, {
    Map<String, MontyValue>? kwargs,
  }) => MontyOsCall(operationName: op, arguments: args, kwargs: kwargs);

  group('SandboxedFsProvider', () {
    // -- Basic FS operations (same contract as VFS) --

    test('write_text + read_text round-trip', () async {
      // Create the file first.
      final f = File('$rootPath/test.txt')..writeAsStringSync('hello');
      expect(f.existsSync(), isTrue);

      final result = await handler.resolve(
        pathCall('Path.read_text', [MontyString('$rootPath/test.txt')]),
      );

      expect(result, 'hello');
    });

    test('write_text creates file inside sandbox', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/new.txt'),
          const MontyString('content'),
        ]),
      );

      expect(File('$rootPath/new.txt').readAsStringSync(), 'content');
    });

    test('write_text returns int (content length)', () async {
      final result = await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/len.txt'),
          const MontyString('hello'),
        ]),
      );

      expect(result, 5);
    });

    test('write_bytes + read_bytes round-trip', () async {
      await handler.resolve(
        pathCall('Path.write_bytes', [
          MontyString('$rootPath/data.bin'),
          const MontyList([MontyInt(65), MontyInt(66)]),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_bytes', [MontyString('$rootPath/data.bin')]),
      );

      expect(result, [65, 66]);
    });

    test('mkdir + iterdir', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/sub')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/sub/a.txt'),
          const MontyString('a'),
        ]),
      );

      final result = await handler.resolve(
        pathCall('Path.iterdir', [MontyString('$rootPath/sub')]),
      );

      expect(result, isA<List<MontyPath>>());
      expect((result! as List<MontyPath>).first.value, contains('a.txt'));
    });

    test('Path.exists true for file, false for missing', () async {
      File('$rootPath/x.txt').writeAsStringSync('x');

      expect(
        await handler.resolve(
          pathCall('Path.exists', [MontyString('$rootPath/x.txt')]),
        ),
        isTrue,
      );
      expect(
        await handler.resolve(
          pathCall('Path.exists', [MontyString('$rootPath/nope.txt')]),
        ),
        isFalse,
      );
    });

    test('unlink removes file', () async {
      File('$rootPath/del.txt').writeAsStringSync('bye');
      await handler.resolve(
        pathCall('Path.unlink', [MontyString('$rootPath/del.txt')]),
      );

      expect(File('$rootPath/del.txt').existsSync(), isFalse);
    });

    test('rename moves file', () async {
      File('$rootPath/old.txt').writeAsStringSync('moved');
      final result = await handler.resolve(
        pathCall('Path.rename', [
          MontyString('$rootPath/old.txt'),
          MontyString('$rootPath/new.txt'),
        ]),
      );

      expect(result, '$rootPath/new.txt');
      expect(File('$rootPath/old.txt').existsSync(), isFalse);
      expect(File('$rootPath/new.txt').readAsStringSync(), 'moved');
    });

    // -- Security tests --

    group('security', () {
      test('path traversal via ../ is rejected', () {
        expect(
          () => handler.resolve(
            pathCall('Path.read_text', [
              MontyString('$rootPath/../../../etc/passwd'),
            ]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('path traversal via /../ in middle is rejected', () {
        expect(
          () => handler.resolve(
            pathCall('Path.read_text', [
              MontyString('$rootPath/sub/../../etc/passwd'),
            ]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('absolute path outside root is rejected', () {
        expect(
          () => handler.resolve(
            pathCall('Path.read_text', [const MontyString('/etc/passwd')]),
          ),
          throwsA(isA<OsCallPermissionError>()),
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
          () => handler.resolve(
            pathCall('Path.read_text', [
              MontyString('${rootPath}evil/secret.txt'),
            ]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('symlink inside sandbox pointing outside is rejected', () {
        // Create a symlink inside the sandbox that points to /tmp.
        final link = Link('$rootPath/escape_link')..createSync('/tmp');

        expect(link.existsSync(), isTrue);

        expect(
          () => handler.resolve(
            pathCall('Path.read_text', [MontyString('$rootPath/escape_link')]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
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
          () => handler.resolve(
            pathCall('Path.read_text', [MontyString('$rootPath/chain_link')]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('Path.resolve on symlink outside sandbox is rejected', () {
        final outsideDir = Directory.systemTemp.createTempSync(
          'monty_resolve_',
        );
        addTearDown(() => outsideDir.deleteSync(recursive: true));

        Link('$rootPath/resolve_link').createSync(outsideDir.path);

        expect(
          () => handler.resolve(
            pathCall('Path.resolve', [MontyString('$rootPath/resolve_link')]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('normalize removes redundant separators', () async {
        File('$rootPath/norm.txt').writeAsStringSync('ok');

        // Double slashes should normalize and still work.
        final result = await handler.resolve(
          pathCall('Path.read_text', [MontyString('$rootPath//norm.txt')]),
        );

        expect(result, 'ok');
      });

      test('write to path outside sandbox is rejected', () {
        expect(
          () => handler.resolve(
            pathCall('Path.write_text', [
              const MontyString('/tmp/escape.txt'),
              const MontyString('pwned'),
            ]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });

      test('rename target outside sandbox is rejected', () {
        File('$rootPath/src.txt').writeAsStringSync('data');

        expect(
          () => handler.resolve(
            pathCall('Path.rename', [
              MontyString('$rootPath/src.txt'),
              const MontyString('/tmp/escaped.txt'),
            ]),
          ),
          throwsA(isA<OsCallPermissionError>()),
        );
      });
    });
  });
}
