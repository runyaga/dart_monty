import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Runs the shared FS handler contract against any [OsCallHandler].
///
/// Both the memory-backed `fsHandler(MemoryFileSystem())` and
/// `sandboxedFsHandler(root:)` must pass this identical suite, proving
/// behavioral parity.
///
/// [name] is used as the test group label.
/// [createHandler] returns a fresh handler for each test.
/// [rootPath] is the base directory path the handler operates in.
/// [cleanUp] is called in tearDown to release resources.
void runFsHandlerContract(
  String name, {
  required Future<OsCallHandler> Function() createHandler,
  required String rootPath,
  Future<void> Function()? cleanUp,
}) {
  late OsCallHandler handler;

  setUp(() async {
    handler = await createHandler();
  });

  tearDown(() async {
    await cleanUp?.call();
  });

  group('$name FS contract', () {
    // -- File CRUD --

    test('write_text + read_text round-trip', () async {
      await handler('Path.write_text', [
        '$rootPath/test.txt',
        'hello world',
      ], null);
      final result = await handler('Path.read_text', [
        '$rootPath/test.txt',
      ], null);
      expect(result, 'hello world');
    });

    test('write_bytes + read_bytes round-trip', () async {
      await handler('Path.write_bytes', [
        '$rootPath/data.bin',
        <int>[72, 105],
      ], null);
      final result = await handler('Path.read_bytes', [
        '$rootPath/data.bin',
      ], null);
      expect(result, [72, 105]);
    });

    test('write_text returns int (content length)', () async {
      final result = await handler('Path.write_text', [
        '$rootPath/len.txt',
        'hello',
      ], null);
      expect(result, isA<int>());
      expect(result, 5);
    });

    test('write_bytes returns int (byte count)', () async {
      final result = await handler('Path.write_bytes', [
        '$rootPath/len.bin',
        <int>[1, 2, 3],
      ], null);
      expect(result, isA<int>());
      expect(result, 3);
    });

    test('read_bytes returns List<int>', () async {
      await handler('Path.write_bytes', [
        '$rootPath/bytes.bin',
        <int>[65, 66, 67],
      ], null);
      final result = await handler('Path.read_bytes', [
        '$rootPath/bytes.bin',
      ], null);
      expect(result, isA<List<int>>());
      expect(result, [65, 66, 67]);
    });

    // -- Directory --

    test('mkdir creates directory', () async {
      await handler('Path.mkdir', ['$rootPath/newdir'], {'parents': true});
      final isDir = await handler('Path.is_dir', ['$rootPath/newdir'], null);
      expect(isDir, isTrue);
    });

    test('mkdir with parents=true creates nested', () async {
      await handler('Path.mkdir', ['$rootPath/a/b/c'], {'parents': true});
      final isDir = await handler('Path.is_dir', ['$rootPath/a/b/c'], null);
      expect(isDir, isTrue);
    });

    test('mkdir with exist_ok=true on existing dir is noop', () async {
      await handler('Path.mkdir', ['$rootPath/existdir'], {'parents': true});
      // Should not throw.
      await handler('Path.mkdir', ['$rootPath/existdir'], {'exist_ok': true});
    });

    test('iterdir lists files', () async {
      await handler('Path.write_text', [
        '$rootPath/ls/a.txt',
        'a',
      ], null);
      await handler('Path.write_text', [
        '$rootPath/ls/b.txt',
        'b',
      ], null);

      final result = await handler('Path.iterdir', ['$rootPath/ls'], null);
      expect(result, isA<List<MontyPath>>());
      final paths = (result! as List<MontyPath>).map((p) => p.value).toList()
        ..sort();
      expect(paths, hasLength(2));
      expect(paths[0], contains('a.txt'));
      expect(paths[1], contains('b.txt'));
    });

    test('iterdir returns List<MontyPath>', () async {
      await handler('Path.write_text', [
        '$rootPath/lsdir/x.txt',
        'x',
      ], null);
      final result = await handler('Path.iterdir', ['$rootPath/lsdir'], null);
      expect(result, isA<List<MontyPath>>());
    });

    // -- Queries --

    test('Path.exists true for existing file', () async {
      await handler('Path.write_text', [
        '$rootPath/exists.txt',
        'yes',
      ], null);
      final result = await handler('Path.exists', [
        '$rootPath/exists.txt',
      ], null);
      expect(result, isTrue);
    });

    test('Path.exists false for missing path', () async {
      final result = await handler('Path.exists', [
        '$rootPath/nope.txt',
      ], null);
      expect(result, isFalse);
    });

    test('Path.is_file true for file, false for dir', () async {
      await handler('Path.write_text', ['$rootPath/f.txt', 'f'], null);
      expect(
        await handler('Path.is_file', ['$rootPath/f.txt'], null),
        isTrue,
      );
      expect(
        await handler('Path.is_file', [rootPath], null),
        isFalse,
      );
    });

    test('Path.is_dir true for dir, false for file', () async {
      await handler('Path.write_text', ['$rootPath/d.txt', 'd'], null);
      expect(
        await handler('Path.is_dir', [rootPath], null),
        isTrue,
      );
      expect(
        await handler('Path.is_dir', ['$rootPath/d.txt'], null),
        isFalse,
      );
    });

    // -- Mutations --

    test('unlink removes file', () async {
      await handler('Path.write_text', [
        '$rootPath/kill.txt',
        'bye',
      ], null);
      await handler('Path.unlink', ['$rootPath/kill.txt'], null);
      final exists = await handler('Path.exists', [
        '$rootPath/kill.txt',
      ], null);
      expect(exists, isFalse);
    });

    test('rmdir removes empty directory', () async {
      await handler('Path.mkdir', ['$rootPath/emptydir'], {'parents': true});
      await handler('Path.rmdir', ['$rootPath/emptydir'], null);
      final exists = await handler('Path.exists', [
        '$rootPath/emptydir',
      ], null);
      expect(exists, isFalse);
    });

    test('rename moves file', () async {
      await handler('Path.write_text', [
        '$rootPath/old.txt',
        'moved',
      ], null);
      final newPath = await handler('Path.rename', [
        '$rootPath/old.txt',
        '$rootPath/new.txt',
      ], null);
      expect(newPath, '$rootPath/new.txt');

      final oldExists = await handler('Path.exists', [
        '$rootPath/old.txt',
      ], null);
      expect(oldExists, isFalse);

      final content = await handler('Path.read_text', [
        '$rootPath/new.txt',
      ], null);
      expect(content, 'moved');
    });

    // -- Path operations --

    test('Path.resolve returns a path string', () async {
      final result = await handler('Path.resolve', [
        '$rootPath/any.txt',
      ], null);
      expect(result, isA<String>());
      expect(result! as String, contains('any.txt'));
    });

    test('Path.absolute returns a path string', () async {
      final result = await handler('Path.absolute', [
        '$rootPath/any.txt',
      ], null);
      expect(result, isA<String>());
      expect(result! as String, contains('any.txt'));
    });
  });
}
