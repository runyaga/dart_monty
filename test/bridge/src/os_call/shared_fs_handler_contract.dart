import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

/// Runs the shared FS handler contract against any [OsProvider].
///
/// Both `MemoryFsProvider` and `SandboxedFsProvider` must
/// pass this identical suite, proving behavioral parity.
///
/// [name] is used as the test group label.
/// [createHandler] returns a fresh handler for each test.
/// [rootPath] is the base directory path the handler operates in.
/// [cleanUp] is called in tearDown to release resources.
void runFsHandlerContract(
  String name, {
  required Future<OsProvider> Function() createHandler,
  required String rootPath,
  Future<void> Function()? cleanUp,
}) {
  late OsProvider handler;

  setUp(() async {
    handler = await createHandler();
  });

  tearDown(() async {
    await handler.dispose();
    await cleanUp?.call();
  });

  MontyOsCall pathCall(
    String op,
    List<MontyValue> args, {
    Map<String, MontyValue>? kwargs,
  }) => MontyOsCall(operationName: op, arguments: args, kwargs: kwargs);

  group('$name FS contract', () {
    // -- File CRUD --

    test('write_text + read_text round-trip', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/test.txt'),
          const MontyString('hello world'),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_text', [MontyString('$rootPath/test.txt')]),
      );
      expect(result, 'hello world');
    });

    test('write_bytes + read_bytes round-trip', () async {
      await handler.resolve(
        pathCall('Path.write_bytes', [
          MontyString('$rootPath/data.bin'),
          const MontyList([MontyInt(72), MontyInt(105)]),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_bytes', [MontyString('$rootPath/data.bin')]),
      );
      expect(result, [72, 105]);
    });

    test('write_text returns int (content length)', () async {
      final result = await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/len.txt'),
          const MontyString('hello'),
        ]),
      );
      expect(result, isA<int>());
      expect(result, 5);
    });

    test('write_bytes returns int (byte count)', () async {
      final result = await handler.resolve(
        pathCall('Path.write_bytes', [
          MontyString('$rootPath/len.bin'),
          const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
        ]),
      );
      expect(result, isA<int>());
      expect(result, 3);
    });

    test('read_bytes returns List<int>', () async {
      await handler.resolve(
        pathCall('Path.write_bytes', [
          MontyString('$rootPath/bytes.bin'),
          const MontyList([MontyInt(65), MontyInt(66), MontyInt(67)]),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.read_bytes', [MontyString('$rootPath/bytes.bin')]),
      );
      expect(result, isA<List<int>>());
      expect(result, [65, 66, 67]);
    });

    // -- Directory --

    test('mkdir creates directory', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/newdir')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      final isDir = await handler.resolve(
        pathCall('Path.is_dir', [MontyString('$rootPath/newdir')]),
      );
      expect(isDir, isTrue);
    });

    test('mkdir with parents=true creates nested', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/a/b/c')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      final isDir = await handler.resolve(
        pathCall('Path.is_dir', [MontyString('$rootPath/a/b/c')]),
      );
      expect(isDir, isTrue);
    });

    test('mkdir with exist_ok=true on existing dir is noop', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/existdir')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      // Should not throw.
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/existdir')],
          kwargs: {'exist_ok': const MontyBool(true)},
        ),
      );
    });

    test('iterdir lists files', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/ls/a.txt'),
          const MontyString('a'),
        ]),
      );
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/ls/b.txt'),
          const MontyString('b'),
        ]),
      );

      final result = await handler.resolve(
        pathCall('Path.iterdir', [MontyString('$rootPath/ls')]),
      );
      expect(result, isA<List<MontyPath>>());
      final paths = (result! as List<MontyPath>).map((p) => p.value).toList()
        ..sort();
      expect(paths, hasLength(2));
      expect(paths[0], contains('a.txt'));
      expect(paths[1], contains('b.txt'));
    });

    test('iterdir returns List<MontyPath>', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/lsdir/x.txt'),
          const MontyString('x'),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.iterdir', [MontyString('$rootPath/lsdir')]),
      );
      expect(result, isA<List<MontyPath>>());
    });

    // -- Queries --

    test('Path.exists true for existing file', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/exists.txt'),
          const MontyString('yes'),
        ]),
      );
      final result = await handler.resolve(
        pathCall('Path.exists', [MontyString('$rootPath/exists.txt')]),
      );
      expect(result, isTrue);
    });

    test('Path.exists false for missing path', () async {
      final result = await handler.resolve(
        pathCall('Path.exists', [MontyString('$rootPath/nope.txt')]),
      );
      expect(result, isFalse);
    });

    test('Path.is_file true for file, false for dir', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/f.txt'),
          const MontyString('f'),
        ]),
      );
      expect(
        await handler.resolve(
          pathCall('Path.is_file', [MontyString('$rootPath/f.txt')]),
        ),
        isTrue,
      );
      expect(
        await handler.resolve(
          pathCall('Path.is_file', [MontyString(rootPath)]),
        ),
        isFalse,
      );
    });

    test('Path.is_dir true for dir, false for file', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/d.txt'),
          const MontyString('d'),
        ]),
      );
      expect(
        await handler.resolve(pathCall('Path.is_dir', [MontyString(rootPath)])),
        isTrue,
      );
      expect(
        await handler.resolve(
          pathCall('Path.is_dir', [MontyString('$rootPath/d.txt')]),
        ),
        isFalse,
      );
    });

    // -- Mutations --

    test('unlink removes file', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/kill.txt'),
          const MontyString('bye'),
        ]),
      );
      await handler.resolve(
        pathCall('Path.unlink', [MontyString('$rootPath/kill.txt')]),
      );
      final exists = await handler.resolve(
        pathCall('Path.exists', [MontyString('$rootPath/kill.txt')]),
      );
      expect(exists, isFalse);
    });

    test('rmdir removes empty directory', () async {
      await handler.resolve(
        pathCall(
          'Path.mkdir',
          [MontyString('$rootPath/emptydir')],
          kwargs: {'parents': const MontyBool(true)},
        ),
      );
      await handler.resolve(
        pathCall('Path.rmdir', [MontyString('$rootPath/emptydir')]),
      );
      final exists = await handler.resolve(
        pathCall('Path.exists', [MontyString('$rootPath/emptydir')]),
      );
      expect(exists, isFalse);
    });

    test('rename moves file', () async {
      await handler.resolve(
        pathCall('Path.write_text', [
          MontyString('$rootPath/old.txt'),
          const MontyString('moved'),
        ]),
      );
      final newPath = await handler.resolve(
        pathCall('Path.rename', [
          MontyString('$rootPath/old.txt'),
          MontyString('$rootPath/new.txt'),
        ]),
      );
      expect(newPath, '$rootPath/new.txt');

      final oldExists = await handler.resolve(
        pathCall('Path.exists', [MontyString('$rootPath/old.txt')]),
      );
      expect(oldExists, isFalse);

      final content = await handler.resolve(
        pathCall('Path.read_text', [MontyString('$rootPath/new.txt')]),
      );
      expect(content, 'moved');
    });

    // -- Path operations --

    test('Path.resolve returns a path string', () async {
      final result = await handler.resolve(
        pathCall('Path.resolve', [MontyString('$rootPath/any.txt')]),
      );
      expect(result, isA<String>());
      expect(result! as String, contains('any.txt'));
    });

    test('Path.absolute returns a path string', () async {
      final result = await handler.resolve(
        pathCall('Path.absolute', [MontyString('$rootPath/any.txt')]),
      );
      expect(result, isA<String>());
      expect(result! as String, contains('any.txt'));
    });
  });
}
