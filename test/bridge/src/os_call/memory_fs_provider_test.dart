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
    // -- File CRUD --

    test('write_text + read_text round-trip', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          const MontyString('/sandbox/test.txt'),
          const MontyString('hello world'),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_text', [const MontyString('/sandbox/test.txt')]),
      );

      expect(result, 'hello world');
    });

    test('write_bytes + read_bytes round-trip', () async {
      await handler.resolve(
        pathCall('Path.write_bytes', [
          const MontyString('/sandbox/data.bin'),
          const MontyList([MontyInt(72), MontyInt(105)]),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_bytes', [const MontyString('/sandbox/data.bin')]),
      );

      expect(result, [72, 105]);
    });

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

    // -- Directory --

    test('mkdir creates directory', () async {
      handler.writeFile('/sandbox/placeholder', '');

      await handler.resolve(
        pathCall('Path.mkdir', [const MontyString('/sandbox/newdir')]),
      );
      final isDir = await handler.resolve(
        pathCall('Path.is_dir', [const MontyString('/sandbox/newdir')]),
      );

      expect(isDir, isTrue);
    });

    test('mkdir with parents=true creates nested', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [const MontyString('/sandbox/a/b/c')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      final isDir = await handler.resolve(
        pathCall('Path.is_dir', [const MontyString('/sandbox/a/b/c')]),
      );

      expect(isDir, isTrue);
    });

    test('mkdir with exist_ok=true on existing dir is noop', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [const MontyString('/sandbox/dir')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );

      // Should not throw.
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [const MontyString('/sandbox/dir')],
          kwargs: {'exist_ok': const MontyBool(true)},
        ),
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

    test('iterdir lists files and subdirs', () async {
      handler
        ..writeFile('/sandbox/dir/a.txt', 'a')
        ..writeFile('/sandbox/dir/b.txt', 'b');

      final result = await handler.resolve(
        pathCall('Path.iterdir', [const MontyString('/sandbox/dir')]),
      );

      expect(result, isA<List<MontyPath>>());
      final paths = (result! as List<MontyPath>).map((p) => p.value).toList()
        ..sort();
      expect(paths, hasLength(2));
      expect(paths[0], contains('a.txt'));
      expect(paths[1], contains('b.txt'));
    });

    test('iterdir on missing dir throws', () {
      expect(
        () => handler.resolve(
          pathCall('Path.iterdir', [const MontyString('/sandbox/nope')]),
        ),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    // -- Queries --

    test('Path.exists true for existing file', () async {
      handler.writeFile('/sandbox/x.txt', 'x');
      final result = await handler.resolve(
        pathCall('Path.exists', [const MontyString('/sandbox/x.txt')]),
      );

      expect(result, isTrue);
    });

    test('Path.exists false for missing path', () async {
      final result = await handler.resolve(
        pathCall('Path.exists', [const MontyString('/sandbox/nope')]),
      );

      expect(result, isFalse);
    });

    test('Path.is_file true for file, false for dir', () async {
      handler.writeFile('/sandbox/f.txt', 'f');

      expect(
        await handler.resolve(
          pathCall('Path.is_file', [const MontyString('/sandbox/f.txt')]),
        ),
        isTrue,
      );
      expect(
        await handler.resolve(
          pathCall('Path.is_file', [const MontyString('/sandbox')]),
        ),
        isFalse,
      );
    });

    test('Path.is_dir true for dir, false for file', () async {
      handler.writeFile('/sandbox/f.txt', 'f');

      expect(
        await handler.resolve(
          pathCall('Path.is_dir', [const MontyString('/sandbox')]),
        ),
        isTrue,
      );
      expect(
        await handler.resolve(
          pathCall('Path.is_dir', [const MontyString('/sandbox/f.txt')]),
        ),
        isFalse,
      );
    });

    // -- Mutations --

    test('unlink removes file', () async {
      handler.writeFile('/sandbox/kill.txt', 'bye');
      await handler.resolve(
        pathCall('Path.unlink', [const MontyString('/sandbox/kill.txt')]),
      );

      expect(handler.exists('/sandbox/kill.txt'), isFalse);
    });

    test('unlink on missing file throws', () {
      expect(
        () => handler.resolve(
          pathCall('Path.unlink', [const MontyString('/sandbox/ghost.txt')]),
        ),
        throwsA(isA<OsCallFileNotFoundError>()),
      );
    });

    test('rmdir removes empty directory', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [const MontyString('/sandbox/empty')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      await handler.resolve(
        pathCall('Path.rmdir', [const MontyString('/sandbox/empty')]),
      );

      expect(handler.exists('/sandbox/empty'), isFalse);
    });

    test('rename moves file', () async {
      handler.writeFile('/sandbox/old.txt', 'content');
      final result = await handler.resolve(
        pathCall('Path.rename', [
          const MontyString('/sandbox/old.txt'),
          const MontyString('/sandbox/new.txt'),
        ]),
      );

      expect(result, '/sandbox/new.txt');
      expect(handler.exists('/sandbox/old.txt'), isFalse);
      expect(handler.readFile('/sandbox/new.txt'), 'content');
    });

    // -- Path operations --

    test('Path.resolve returns path string', () async {
      final result = await handler.resolve(
        pathCall('Path.resolve', [const MontyString('/sandbox/test.txt')]),
      );

      expect(result, '/sandbox/test.txt');
    });

    test('Path.absolute returns path string', () async {
      final result = await handler.resolve(
        pathCall('Path.absolute', [const MontyString('/sandbox/test.txt')]),
      );

      expect(result, '/sandbox/test.txt');
    });

    // -- Return type contracts (parity with native) --

    test('write_text returns int (content length)', () async {
      final result = await handler.resolve(
        pathCall('Path.write_text', [
          const MontyString('/sandbox/len.txt'),
          const MontyString('hello'),
        ]),
      );

      expect(result, isA<int>());
      expect(result, 5);
    });

    test('write_bytes returns int (byte count)', () async {
      final result = await handler.resolve(
        pathCall('Path.write_bytes', [
          const MontyString('/sandbox/len.bin'),
          const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
        ]),
      );

      expect(result, isA<int>());
      expect(result, 3);
    });

    test('read_bytes returns List<int>', () async {
      handler.writeFileBytes('/sandbox/bytes.bin', [65, 66, 67]);
      final result = await handler.resolve(
        pathCall('Path.read_bytes', [const MontyString('/sandbox/bytes.bin')]),
      );

      expect(result, isA<List<int>>());
      expect(result, [65, 66, 67]);
    });

    test('iterdir returns List<MontyPath>', () async {
      handler.writeFile('/sandbox/ls/x.txt', 'x');
      final result = await handler.resolve(
        pathCall('Path.iterdir', [const MontyString('/sandbox/ls')]),
      );

      expect(result, isA<List<MontyPath>>());
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
