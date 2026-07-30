// Does dart_monty's open()/file-I/O handler logic work on both VM and WASM?
//
// Exercises the handler directly (no engine needed) so it runs unchanged on
// dart2js/Chrome — fsHandler/memoryFsHandler use MemoryFileSystem, no dart:io.
// This is the dart_monty-side WASM coverage for the Open OS-call wiring; the
// end-to-end Python `open()` flow is validated in dart_monty_core's WASM
// corpus.
//
// Run on both: dart test -p vm     test/experiments/file_io_wasm_test.dart
//              dart test -p chrome test/experiments/file_io_wasm_test.dart

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBytes, MontyFileHandle;
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('open() handler on current platform', () {
    test('Open w returns a MontyFileHandle and truncates', () async {
      final h = fsHandler(MemoryFileSystem());
      final result = await h('open', ['/out.txt', 'w'], null);
      expect(result, isA<MontyFileHandle>());
      expect((result! as MontyFileHandle).mode, 'w');

      // The truncate effect created the (empty) file.
      expect(await h('Path.exists', ['/out.txt'], null), isTrue);
    });

    test('Open r on an existing file returns a read handle', () async {
      final fs = MemoryFileSystem();
      fs.file('/a.txt').writeAsStringSync('hi');
      final h = fsHandler(fs);
      final result = await h('open', ['/a.txt', 'r'], null);
      expect((result! as MontyFileHandle).path, '/a.txt');
    });

    test('Open r on a missing file throws a typed FileNotFoundError', () async {
      final h = fsHandler(MemoryFileSystem());
      await expectLater(
        () => h('open', ['/nope.txt', 'r'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('append_text + read_bytes round-trip (typed MontyBytes)', () async {
      final h = fsHandler(MemoryFileSystem());
      await h('Path.append_text', ['/log.txt', 'a'], null);
      await h('Path.append_text', ['/log.txt', 'b'], null);
      final bytes = await h('Path.read_bytes', ['/log.txt'], null);
      expect(bytes, isA<MontyBytes>());
      expect((bytes! as MontyBytes).value, 'ab'.codeUnits);
    });

    test(
      'read-only handler rejects Open for write with PermissionError',
      () async {
        final h = fsHandler(MemoryFileSystem()).readOnly();
        await expectLater(
          () => h('open', ['/x.txt', 'w'], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'PermissionError',
            ),
          ),
        );
      },
    );
  });
}
