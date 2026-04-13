// Tests for MemoryFsProvider behavior NOT covered by the shared contract.
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
//   - Dart-side API (writeFile, readFile, exists)

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFsProvider handler;

  setUp(() {
    handler = MemoryFsProvider();
  });

  MontyOsCall pathCall(
    String op,
    List<MontyValue> args, {
    Map<String, MontyValue>? kwargs,
  }) => MontyOsCall(operationName: op, arguments: args, kwargs: kwargs);

  group('MemoryFsProvider', () {
    // -- Error behavior --

    test('read_text on missing file throws', () async {
      expect(
        () => handler.resolve(
          pathCall('Path.read_text', [
            const MontyString('/sandbox/missing.txt'),
          ]),
        ),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    test('mkdir without exist_ok on existing dir throws', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [const MontyString('/sandbox/dir')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );

      expect(
        () => handler.resolve(
          pathCall('Path.mkdir', [const MontyString('/sandbox/dir')]),
        ),
        throwsA(isA<OsCallException>()),
      );
    });

    test('iterdir on missing dir throws', () {
      expect(
        () => handler.resolve(
          pathCall('Path.iterdir', [const MontyString('/sandbox/nope')]),
        ),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    test('unlink on missing file throws', () {
      expect(
        () => handler.resolve(
          pathCall('Path.unlink', [const MontyString('/sandbox/ghost.txt')]),
        ),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    // -- Implicit intermediate directory creation --

    test('write_text creates intermediate directories', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          const MontyString('/sandbox/a/b/c/deep.txt'),
          const MontyString('deep'),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_text', [
          const MontyString('/sandbox/a/b/c/deep.txt'),
        ]),
      );

      expect(result, 'deep');
    });

    // -- Dart-side API --

    test('writeFile and readFile work from Dart', () {
      handler.writeFile('/data/test.json', '{"a": 1}');
      expect(handler.readFile('/data/test.json'), '{"a": 1}');
    });

    test('exists() checks both files and directories', () {
      handler.writeFile('/data/file.txt', 'f');
      expect(handler.exists('/data/file.txt'), isTrue);
      expect(handler.exists('/data'), isTrue);
      expect(handler.exists('/nope'), isFalse);
    });
  });
}
