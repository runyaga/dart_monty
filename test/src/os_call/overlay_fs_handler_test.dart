import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('overlayFsHandler', () {
    late MemoryFileSystem baseFs;
    late MemoryFileSystem scratchFs;
    late OsCallHandler base;
    late OsCallHandler scratch;
    late OsCallHandler overlay;

    setUp(() {
      baseFs = MemoryFileSystem();
      baseFs.file('/project/readme.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# My Project');
      baseFs.file('/project/src/main.py')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('print("hello")');

      scratchFs = MemoryFileSystem();

      base = fsHandler(baseFs);
      scratch = fsHandler(scratchFs);
      overlay = overlayFsHandler(base: base, scratch: scratch);
    });

    // -- Reads fall through to base --

    test('read_text from base layer', () async {
      final result = await overlay('Path.read_text', [
        '/project/readme.md',
      ], null);

      expect(result, '# My Project');
    });

    test('exists checks base layer', () async {
      expect(
        await overlay('Path.exists', ['/project/readme.md'], null),
        isTrue,
      );
    });

    test('is_file checks base layer', () async {
      expect(
        await overlay('Path.is_file', ['/project/src/main.py'], null),
        isTrue,
      );
    });

    // -- Writes go to scratch --

    test('write_text goes to scratch, base unchanged', () async {
      await overlay('Path.write_text', [
        '/project/src/main.py',
        'print("modified")',
      ], null);

      // Scratch has the modification
      expect(
        scratchFs.file('/project/src/main.py').readAsStringSync(),
        'print("modified")',
      );

      // Base is untouched
      expect(
        baseFs.file('/project/src/main.py').readAsStringSync(),
        'print("hello")',
      );
    });

    test('read after write returns scratch version', () async {
      await overlay('Path.write_text', [
        '/project/readme.md',
        '# Modified',
      ], null);

      final result = await overlay('Path.read_text', [
        '/project/readme.md',
      ], null);

      expect(result, '# Modified');
    });

    test('write new file to scratch', () async {
      await overlay('Path.write_text', [
        '/project/new_file.txt',
        'new content',
      ], null);

      expect(
        await overlay('Path.exists', ['/project/new_file.txt'], null),
        isTrue,
      );

      expect(
        await overlay('Path.read_text', ['/project/new_file.txt'], null),
        'new content',
      );

      // Not in base
      expect(baseFs.file('/project/new_file.txt').existsSync(), isFalse);
    });

    // -- iterdir merges layers --

    test('iterdir merges base and scratch', () async {
      // Write a new file to scratch
      await overlay('Path.write_text', [
        '/project/added.txt',
        'extra',
      ], null);

      final result = await overlay('Path.iterdir', ['/project'], null);

      expect(result, isA<List<MontyPath>>());
      final paths = (result! as List<MontyPath>).map((p) => p.value).toSet();
      // Should contain base files and scratch file
      expect(paths, contains(contains('readme.md')));
      expect(paths, contains(contains('added.txt')));
    });

    // -- Delete semantics --

    test('unlink scratch file works', () async {
      // Write then delete from scratch
      await overlay('Path.write_text', [
        '/project/temp.txt',
        'temp',
      ], null);
      await overlay('Path.unlink', ['/project/temp.txt'], null);

      expect(
        await overlay('Path.exists', ['/project/temp.txt'], null),
        // Still exists in... neither scratch nor base
        isFalse,
      );
    });

    test('unlink base-only file throws PermissionError', () {
      expect(
        () => overlay('Path.unlink', ['/project/readme.md'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('rmdir base-only dir throws PermissionError', () {
      expect(
        () => overlay('Path.rmdir', ['/project/src'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    // -- Non-path operations delegate to base --

    test('non-path operations delegate to base', () async {
      // Compose with time handler on base
      final time = timeHandler();
      final baseWithTime = composeOsHandlers({
        'Path.': base,
        'date.': time,
      });
      final overlayWithTime = overlayFsHandler(
        base: baseWithTime,
        scratch: scratch,
      );

      final result = await overlayWithTime('date.today', const [], null);

      expect(result, isA<Map<String, Object?>>());
      expect((result! as Map)['__type'], 'date');
    });
  });
}
