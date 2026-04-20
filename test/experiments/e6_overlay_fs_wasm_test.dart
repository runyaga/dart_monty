// E6: Does overlayFsHandler work correctly on both VM and WASM?
// Both use MemoryFileSystem — no dart:io required.
// Run on both: dart test -p vm test/experiments/e6_overlay_fs_wasm_test.dart
//              dart test -p chrome test/experiments/e6_overlay_fs_wasm_test.dart

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('E6: overlayFsHandler on current platform', () {
    late OsCallHandler overlay;

    setUp(() {
      final baseFs = MemoryFileSystem();
      baseFs.file('/base/readme.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('base content');

      final scratchFs = MemoryFileSystem();

      overlay = overlayFsHandler(
        base: fsHandler(baseFs),
        scratch: fsHandler(scratchFs),
      );
    });

    test('E6a: read from base layer', () async {
      final result = await overlay('Path.read_text', ['/base/readme.md'], null);
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E6a RESULT: read_text = $result');
      expect(result, 'base content');
    });

    test('E6b: write goes to scratch, base unchanged', () async {
      await overlay('Path.write_text', ['/base/readme.md', 'modified'], null);
      final result = await overlay('Path.read_text', ['/base/readme.md'], null);
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E6b RESULT: after write, read_text = $result');
      expect(result, 'modified');
    });

    test('E6c: new file in scratch, not in base', () async {
      await overlay('Path.write_text', ['/new/file.txt', 'new'], null);
      final exists = await overlay('Path.exists', ['/new/file.txt'], null);
      // Experiment test: output is the observable result.
      // ignore: avoid_print
      print('E6c RESULT: new file exists = $exists');
      expect(exists, isTrue);
    });

    test(
      'E6d: memoryFsHandler isolation — two fresh handlers do not share',
      () async {
        final h1 = memoryFsHandler();
        final h2 = memoryFsHandler();
        await h1('Path.write_text', ['/x.txt', 'h1 data'], null);
        final h2Sees = await h2('Path.exists', ['/x.txt'], null);
        // Experiment test: output is the observable result.
        // ignore: avoid_print
        print('E6d RESULT: h2 sees h1 file = $h2Sees (expected: false)');
        expect(h2Sees, isFalse);
      },
    );
  });
}
