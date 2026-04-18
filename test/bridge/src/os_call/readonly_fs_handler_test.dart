import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('readOnlyHandler', () {
    late MemoryFileSystem fs;
    late OsCallHandler inner;
    late OsCallHandler ro;

    setUp(() {
      fs = MemoryFileSystem();
      fs.file('/data/hello.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('hello world');

      inner = fsHandler(fs);
      ro = readOnlyHandler(inner);
    });

    // -- Reads pass through --

    test('read_text passes through', () async {
      final result = await ro('Path.read_text', ['/data/hello.txt'], null);

      expect(result, 'hello world');
    });

    test('exists passes through', () async {
      expect(
        await ro('Path.exists', ['/data/hello.txt'], null),
        isTrue,
      );
      expect(await ro('Path.exists', ['/nope'], null), isFalse);
    });

    test('is_file passes through', () async {
      final result = await ro('Path.is_file', ['/data/hello.txt'], null);

      expect(result, isTrue);
    });

    test('is_dir passes through', () async {
      final result = await ro('Path.is_dir', ['/data'], null);

      expect(result, isTrue);
    });

    test('iterdir passes through', () async {
      final result = await ro('Path.iterdir', ['/data'], null);

      expect(result, isA<List<MontyPath>>());
      expect((result! as List<MontyPath>).first.value, contains('hello.txt'));
    });

    // -- Writes blocked --

    test('write_text throws PermissionError', () {
      expect(
        () => ro('Path.write_text', ['/data/new.txt', 'blocked'], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('write_bytes throws PermissionError', () {
      expect(
        () => ro('Path.write_bytes', [
          '/data/new.bin',
          <int>[1],
        ], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('mkdir throws PermissionError', () {
      expect(
        () => ro('Path.mkdir', ['/data/newdir'], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('unlink throws PermissionError', () {
      expect(
        () => ro('Path.unlink', ['/data/hello.txt'], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('rmdir throws PermissionError', () {
      expect(
        () => ro('Path.rmdir', ['/data'], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });

    test('rename throws PermissionError', () {
      expect(
        () => ro('Path.rename', [
          '/data/hello.txt',
          '/data/moved.txt',
        ], null),
        throwsA(isA<OsCallPermissionError>()),
      );
    });
  });
}
