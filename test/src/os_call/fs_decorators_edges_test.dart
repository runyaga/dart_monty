// The overlay decorator's error contract, and the sugar nothing called.
//
// lib/src/os_call/fs_decorators.dart is the lowest-covered file in this
// package on MERGED unit+integration coverage — 55/69 = 79.7%. The existing
// overlay_fs_handler_test.dart has eleven cases and they all take the happy
// path: read falls through, write lands in scratch, listing merges.
//
// What was uncovered is the part that decides what a MISSING layer means:
//
//   fs_decorators.dart:114-115  scratch dir absent -> swallow NotFound,
//                               rethrow anything else
//   fs_decorators.dart:126-134  base dir absent    -> raise FileNotFoundError
//                               only if scratch contributed nothing either
//   fs_decorators.dart:163-166  PathOp.open routes by MODE — write to
//                               scratch, read through the fallback.
//                               NOTE PathOp.open is 'open', NOT
//                               'Path.open' — the builtin carries no
//                               prefix (path_op.dart:45-53). Getting that
//                               wrong does not fail loudly at the call
//                               site; it falls through to
//                               OsCallNotHandledException.
//   fs_decorators.dart:203-204  `overlayWith`, public sugar with no callers
//
// A directory listing that silently returns empty instead of raising, or an
// `open(...,'w')` that lands in the read-only base, are both failures a
// happy-path suite cannot see.
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('overlay listing when a layer is missing', () {
    late MemoryFileSystem baseFs;
    late MemoryFileSystem scratchFs;
    late OsCallHandler overlay;

    setUp(() {
      baseFs = MemoryFileSystem();
      baseFs.file('/p/base_only.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('b');

      scratchFs = MemoryFileSystem();
      scratchFs.file('/only_scratch/s.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('s');

      overlay = overlayFsHandler(
        base: fsHandler(baseFs),
        scratch: fsHandler(scratchFs),
      );
    });

    test('a directory present ONLY in scratch still lists', () async {
      // Reaching this exercises the base-missing catch: base has no
      // /only_scratch, so it raises NotFound, and the merge must survive it
      // because scratch contributed entries.
      final entries = await overlay('Path.iterdir', ['/only_scratch'], null);

      expect(entries, isA<List<MontyPath>>());
      expect(
        (entries! as List<MontyPath>).map((e) => e.value),
        contains(contains('s.txt')),
      );
    });

    test('a directory present ONLY in base still lists', () async {
      // The mirror case: scratch raises NotFound and the merge survives it
      // because base contributed.
      final entries = await overlay('Path.iterdir', ['/p'], null);

      expect(
        (entries! as List<MontyPath>).map((e) => e.value),
        contains(contains('base_only.txt')),
      );
    });

    test('a directory in NEITHER layer raises FileNotFoundError', () async {
      // Both catches fire and nothing was merged. Returning an empty list here
      // would be the silent failure: Python would see an empty directory
      // rather than a missing one.
      await expectLater(
        overlay('Path.iterdir', ['/nowhere'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });
  });

  group('overlay open() routes by mode', () {
    late MemoryFileSystem baseFs;
    late MemoryFileSystem scratchFs;
    late OsCallHandler overlay;

    setUp(() {
      baseFs = MemoryFileSystem();
      baseFs.file('/p/f.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('from base');
      scratchFs = MemoryFileSystem();
      overlay = overlayFsHandler(
        base: fsHandler(baseFs),
        scratch: fsHandler(scratchFs),
      );
    });

    test('open for READ falls through to base', () async {
      final r = await overlay('open', ['/p/f.txt', 'r'], null);

      expect(r, isNotNull);
      // The base copy is untouched by a read.
      expect(baseFs.file('/p/f.txt').readAsStringSync(), 'from base');
    });

    test('open for WRITE goes to scratch, leaving base intact', () async {
      // This is copy-on-write's whole point. A route that sent the write to
      // `base` would mutate the read-only layer, and every read-path test in
      // the sibling suite would still pass.
      await overlay('open', ['/p/new.txt', 'w'], null);

      expect(
        baseFs.file('/p/new.txt').existsSync(),
        isFalse,
        reason: 'the base layer must never receive a write',
      );
      expect(scratchFs.file('/p/new.txt').existsSync(), isTrue);
    });
  });

  group('DecoratorHandlers sugar', () {
    test('overlayWith builds the same overlay as the function', () async {
      // Public API with no callers anywhere in lib/, test/ or example/. It
      // exists so `base.overlayWith(scratch)` reads naturally; if it wired the
      // layers backwards, writes would land in the read-only base and nothing
      // would have noticed.
      final baseFs = MemoryFileSystem();
      baseFs.file('/p/f.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('base');
      final scratchFs = MemoryFileSystem();

      final overlay = fsHandler(baseFs).overlayWith(fsHandler(scratchFs));

      // Reads see base...
      final read = await overlay('Path.read_text', ['/p/f.txt'], null);
      expect(read, 'base');

      // ...and writes land in scratch, not base.
      await overlay('Path.write_text', ['/p/f.txt', 'changed'], null);
      expect(baseFs.file('/p/f.txt').readAsStringSync(), 'base');
      expect(scratchFs.file('/p/f.txt').readAsStringSync(), 'changed');
    });

    test('readOnly() refuses writes with PermissionError', () async {
      final fs = MemoryFileSystem();
      fs.file('/p/f.txt')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');

      final ro = fsHandler(fs).readOnly();

      expect(await ro('Path.read_text', ['/p/f.txt'], null), 'x');

      // SYNCHRONOUS throw. readOnlyHandler returns a non-async closure
      // (fs_decorators.dart:39-44), so the refusal is raised when the handler
      // is CALLED, not when its Future is awaited — `expectLater(ro(...))`
      // never sees it because the throw happens while building the argument.
      expect(
        () => ro('Path.write_text', ['/p/f.txt', 'nope'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
      expect(fs.file('/p/f.txt').readAsStringSync(), 'x');
    });
  });
}
