// Tests for memory-backed `fsHandler` / `memoryFsHandler` behavior
// NOT covered by the shared contract.
//
// The shared FS handler contract (run via memory_fs_contract_test.dart)
// covers:
//   - File CRUD: write/read text & bytes round-trips, return types
//   - Directory: mkdir (with parents, exist_ok), iterdir, rmdir
//   - Queries: exists, is_file, is_dir
//   - Mutations: unlink, rename
//   - Path ops: resolve, absolute
//
// This file tests only:
//   - Error behavior (read/unlink/iterdir on missing paths,
//     mkdir without exist_ok)
//   - Implicit intermediate directory creation on write_text
//   - Dart-side introspection via the held MemoryFileSystem reference

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late OsCallHandler handler;

  setUp(() {
    fs = MemoryFileSystem();
    handler = fsHandler(fs);
  });

  group('memory fsHandler', () {
    // -- Error behavior --

    test('read_text on missing file throws', () async {
      expect(
        () => handler('Path.read_text', ['/sandbox/missing.txt'], null),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    test('mkdir without exist_ok on existing dir throws', () async {
      await handler('Path.mkdir', ['/sandbox/dir'], {'parents': true});

      expect(
        () => handler('Path.mkdir', ['/sandbox/dir'], null),
        throwsA(isA<OsCallException>()),
      );
    });

    test('iterdir on missing dir throws', () {
      expect(
        () => handler('Path.iterdir', ['/sandbox/nope'], null),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    test('unlink on missing file throws', () {
      expect(
        () => handler('Path.unlink', ['/sandbox/ghost.txt'], null),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    // -- Implicit intermediate directory creation --

    test('write_text creates intermediate directories', () async {
      await handler('Path.write_text', [
        '/sandbox/a/b/c/deep.txt',
        'deep',
      ], null);
      final result = await handler('Path.read_text', [
        '/sandbox/a/b/c/deep.txt',
      ], null);

      expect(result, 'deep');
    });

    // -- Dart-side introspection via the held MemoryFileSystem reference --

    test('Dart-side writes via fs are visible through handler', () async {
      fs.file('/data/test.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"a": 1}');

      final result = await handler('Path.read_text', [
        '/data/test.json',
      ], null);
      expect(result, '{"a": 1}');
    });

    test('handler writes are visible via the fs reference', () async {
      await handler('Path.write_text', ['/data/note.txt', 'hi'], null);

      expect(fs.file('/data/note.txt').readAsStringSync(), 'hi');
    });

    test('exists reflects both files and directories created by fs', () async {
      fs.file('/data/file.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('f');

      expect(
        await handler('Path.exists', ['/data/file.txt'], null),
        isTrue,
      );
      expect(await handler('Path.exists', ['/data'], null), isTrue);
      expect(await handler('Path.exists', ['/nope'], null), isFalse);
    });

    test('memoryFsHandler() returns a fresh handler each call', () async {
      final h1 = memoryFsHandler();
      final h2 = memoryFsHandler();

      await h1('Path.write_text', ['/a.txt', 'from h1'], null);
      // h2 should not see h1's file — fresh in-memory FS per factory call.
      expect(await h2('Path.exists', ['/a.txt'], null), isFalse);
    });
  });
}
