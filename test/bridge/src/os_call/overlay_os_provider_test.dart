import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall pathCall(String op, [List<MontyValue> args = const []]) =>
      MontyOsCall(operationName: op, arguments: args);

  group('OverlayFsProvider', () {
    late MemoryFsOsProvider base;
    late MemoryFsOsProvider scratch;
    late OverlayFsProvider overlay;

    setUp(() {
      base = MemoryFsOsProvider()
        ..writeFile('/project/readme.md', '# My Project')
        ..writeFile('/project/src/main.py', 'print("hello")');

      scratch = MemoryFsOsProvider();
      overlay = OverlayFsProvider(base: base, scratch: scratch);
    });

    // -- Reads fall through to base --

    test('read_text from base layer', () async {
      final result = await overlay.resolve(
        pathCall('Path.read_text', [const MontyString('/project/readme.md')]),
      );

      expect(result, '# My Project');
    });

    test('exists checks base layer', () async {
      expect(
        await overlay.resolve(
          pathCall('Path.exists', [const MontyString('/project/readme.md')]),
        ),
        isTrue,
      );
    });

    test('is_file checks base layer', () async {
      expect(
        await overlay.resolve(
          pathCall(
            'Path.is_file',
            [const MontyString('/project/src/main.py')],
          ),
        ),
        isTrue,
      );
    });

    // -- Writes go to scratch --

    test('write_text goes to scratch, base unchanged', () async {
      await overlay.resolve(
        pathCall('Path.write_text', [
          const MontyString('/project/src/main.py'),
          const MontyString('print("modified")'),
        ]),
      );

      // Scratch has the modification
      expect(scratch.readFile('/project/src/main.py'), 'print("modified")');

      // Base is untouched
      expect(base.readFile('/project/src/main.py'), 'print("hello")');
    });

    test('read after write returns scratch version', () async {
      await overlay.resolve(
        pathCall('Path.write_text', [
          const MontyString('/project/readme.md'),
          const MontyString('# Modified'),
        ]),
      );

      final result = await overlay.resolve(
        pathCall('Path.read_text', [const MontyString('/project/readme.md')]),
      );

      expect(result, '# Modified');
    });

    test('write new file to scratch', () async {
      await overlay.resolve(
        pathCall('Path.write_text', [
          const MontyString('/project/new_file.txt'),
          const MontyString('new content'),
        ]),
      );

      expect(
        await overlay.resolve(
          pathCall('Path.exists', [const MontyString('/project/new_file.txt')]),
        ),
        isTrue,
      );

      expect(
        await overlay.resolve(
          pathCall(
            'Path.read_text',
            [const MontyString('/project/new_file.txt')],
          ),
        ),
        'new content',
      );

      // Not in base
      expect(base.exists('/project/new_file.txt'), isFalse);
    });

    // -- iterdir merges layers --

    test('iterdir merges base and scratch', () async {
      // Write a new file to scratch
      await overlay.resolve(
        pathCall('Path.write_text', [
          const MontyString('/project/added.txt'),
          const MontyString('extra'),
        ]),
      );

      final result = await overlay.resolve(
        pathCall('Path.iterdir', [const MontyString('/project')]),
      );

      expect(result, isA<List<MontyPath>>());
      final paths = (result! as List<MontyPath>).map((p) => p.value).toSet();
      // Should contain base files and scratch file
      expect(paths, contains(contains('readme.md')));
      expect(paths, contains(contains('added.txt')));
    });

    // -- Delete semantics --

    test('unlink scratch file works', () async {
      // Write then delete from scratch
      await overlay.resolve(
        pathCall('Path.write_text', [
          const MontyString('/project/temp.txt'),
          const MontyString('temp'),
        ]),
      );
      await overlay.resolve(
        pathCall('Path.unlink', [const MontyString('/project/temp.txt')]),
      );

      expect(
        await overlay.resolve(
          pathCall('Path.exists', [const MontyString('/project/temp.txt')]),
        ),
        // Still exists in... neither scratch nor base
        isFalse,
      );
    });

    test('unlink base-only file throws PermissionError', () {
      expect(
        () => overlay.resolve(
          pathCall('Path.unlink', [const MontyString('/project/readme.md')]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('rmdir base-only dir throws PermissionError', () {
      expect(
        () => overlay.resolve(
          pathCall('Path.rmdir', [const MontyString('/project/src')]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    // -- Non-path operations delegate to base --

    test('non-path operations delegate to base', () async {
      // Compose with time provider on base
      final timeProvider = TimeOsProvider();
      final baseWithTime = OsProvider.compose({
        'Path.': base,
        'date.': timeProvider,
      });
      final overlayWithTime = OverlayFsProvider(
        base: baseWithTime,
        scratch: scratch,
      );

      final result = await overlayWithTime.resolve(
        const MontyOsCall(operationName: 'date.today', arguments: []),
      );

      expect(result, isA<Map<String, Object?>>());
      expect((result! as Map)['__type'], 'date');
    });

    test('dispose disposes both layers', () async {
      await overlay.dispose();
      // No crash — both disposed
    });
  });
}
