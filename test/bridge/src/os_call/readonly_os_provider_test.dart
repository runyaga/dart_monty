import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  MontyOsCall pathCall(String op, [List<MontyValue> args = const []]) =>
      MontyOsCall(operationName: op, arguments: args);

  group('ReadOnlyOsProvider', () {
    late MemoryFsOsProvider vfs;
    late ReadOnlyOsProvider ro;

    setUp(() {
      vfs = MemoryFsOsProvider()
        ..writeFile('/data/hello.txt', 'hello world');
      ro = ReadOnlyOsProvider(vfs);
    });

    // -- Reads pass through --

    test('read_text passes through', () async {
      final result = await ro.resolve(
        pathCall('Path.read_text', [const MontyString('/data/hello.txt')]),
      );

      expect(result, 'hello world');
    });

    test('exists passes through', () async {
      expect(
        await ro.resolve(
          pathCall('Path.exists', [const MontyString('/data/hello.txt')]),
        ),
        isTrue,
      );
      expect(
        await ro.resolve(
          pathCall('Path.exists', [const MontyString('/nope')]),
        ),
        isFalse,
      );
    });

    test('is_file passes through', () async {
      final result = await ro.resolve(
        pathCall('Path.is_file', [const MontyString('/data/hello.txt')]),
      );

      expect(result, isTrue);
    });

    test('is_dir passes through', () async {
      final result = await ro.resolve(
        pathCall('Path.is_dir', [const MontyString('/data')]),
      );

      expect(result, isTrue);
    });

    test('iterdir passes through', () async {
      final result = await ro.resolve(
        pathCall('Path.iterdir', [const MontyString('/data')]),
      );

      expect(result, isA<List<MontyPath>>());
      expect((result! as List<MontyPath>).first.value, contains('hello.txt'));
    });

    // -- Writes blocked --

    test('write_text throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.write_text', [
            const MontyString('/data/new.txt'),
            const MontyString('blocked'),
          ]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('write_bytes throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.write_bytes', [
            const MontyString('/data/new.bin'),
            const MontyList([MontyInt(1)]),
          ]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('mkdir throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.mkdir', [const MontyString('/data/newdir')]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('unlink throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.unlink', [const MontyString('/data/hello.txt')]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('rmdir throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.rmdir', [const MontyString('/data')]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('rename throws PermissionError', () {
      expect(
        () => ro.resolve(
          pathCall('Path.rename', [
            const MontyString('/data/hello.txt'),
            const MontyString('/data/moved.txt'),
          ]),
        ),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('dispose delegates to inner', () async {
      await ro.dispose();
      // Inner was disposed — no crash
    });
  });
}
