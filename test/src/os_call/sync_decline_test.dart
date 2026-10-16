// A decline stays synchronous through every handler, decorator and composer.
//
// Core honours only a synchronous throw of `OsCallNotHandledException`; a
// returned `Future` that fails with it raises `TypeError`. The handlers used to
// be `async` closures, which turned every decline into a failed future. These
// tests call the handlers WITHOUT `async`, so the difference is observable.
import 'dart:async';
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/os_call/os_error_mapping.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import '_os_call.dart';

void main() {
  OsHandler declining() =>
      (operation, args, kwargs) => throw const OsCallNotHandledException();
  OsHandler notFound() =>
      (operation, args, kwargs) =>
          throw const ExternalException('FileNotFoundError', 'gone');
  OsHandler answering(MontyValue value) =>
      (operation, args, kwargs) => value;

  group('the file handlers decline synchronously', () {
    test('fsHandler: an unknown op', () {
      final h = fsHandler(MemoryFileSystem());

      expectSyncDecline(() => rawCall(h, 'Path.stat', ['/a.txt']));
    });

    test('memoryFsHandler: an unknown op', () {
      expectSyncDecline(() => rawCall(memoryFsHandler(), 'Path.stat', ['/a']));
    });

    test('sandboxedFsHandler: an unknown op and a non-string path', () {
      final root = Directory.systemTemp.createTempSync('d15_decline_');
      addTearDown(() => root.deleteSync(recursive: true));
      final h = sandboxedFsHandler(root: root);

      expectSyncDecline(() => rawCall(h, 'Path.stat', ['a.txt']));
      expectSyncDecline(() => rawCall(h, 'Path.exists'));
    });

    test('a handled op answers synchronously with a MontyValue', () {
      final fs = MemoryFileSystem()..file('/a.txt').createSync();
      final root = Directory.systemTemp.createTempSync('d15_sync_');
      addTearDown(() => root.deleteSync(recursive: true));

      expect(
        rawCall(fsHandler(fs), 'Path.exists', ['/a.txt']),
        const MontyBool(true),
      );
      expect(
        rawCall(sandboxedFsHandler(root: root), 'Path.exists', ['nope']),
        const MontyBool(false),
      );
      expect(
        rawCall(envHandler(const {'K': 'v'}), 'os.getenv', ['K']),
        const MontyString('v'),
      );
    });

    test('a typed failure is still thrown synchronously', () {
      final h = fsHandler(MemoryFileSystem());

      expect(
        () => rawCall(h, 'Path.read_text', ['/missing']),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('mapIoErrors passes a decline through synchronously', () {
      expectSyncDecline(() => rawCall(mapIoErrors(declining()), 'Path.x'));
    });

    test('mapIoErrors maps a FileSystemException thrown synchronously', () {
      final h = mapIoErrors(
        (operation, args, kwargs) =>
            throw const FileSystemException('x', '/p', OSError('boom', 13)),
      );

      expect(
        () => rawCall(h, 'Path.write_text'),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'PermissionError',
          ),
        ),
      );
    });

    test('mapIoErrors maps a FileSystemException from a Future', () async {
      final h = mapIoErrors(
        (operation, args, kwargs) async =>
            throw const FileSystemException('x', '/p', OSError('gone', 2)),
      );

      final result = rawCall(h, 'Path.read_text');
      expect(result, isA<Future<MontyValue>>());
      await expectLater(
        result,
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'FileNotFoundError',
          ),
        ),
      );
    });
  });

  group('decorated handlers decline synchronously', () {
    test('readOnlyHandler: an unknown op reaches the inner decline', () {
      final h = readOnlyHandler(fsHandler(MemoryFileSystem()));

      expectSyncDecline(() => rawCall(h, 'Path.stat', ['/a.txt']));
      // A write is refused by the decorator itself, also synchronously.
      expect(
        () => rawCall(h, PathOp.writeText, ['/a.txt', 'x']),
        throwsA(isA<ExternalException>()),
      );
    });

    test('.readOnly().overlayWith(): an unknown op', () {
      final h = fsHandler(
        MemoryFileSystem(),
      ).readOnly().overlayWith(fsHandler(MemoryFileSystem()));

      expectSyncDecline(() => rawCall(h, 'Path.stat', ['/a.txt']));
    });

    for (final op in [
      PathOp.readText,
      PathOp.exists,
      PathOp.iterdir,
      PathOp.unlink,
      PathOp.open,
    ]) {
      test('overlayFsHandler: a declining scratch declines $op', () {
        final h = overlayFsHandler(
          base: fsHandler(MemoryFileSystem()),
          scratch: declining(),
        );

        expectSyncDecline(() => rawCall(h, op, ['/f']));
      });
    }

    test('overlayFsHandler: base declining after a scratch miss declines', () {
      final h = overlayFsHandler(base: declining(), scratch: notFound());

      expectSyncDecline(() => rawCall(h, PathOp.readText, ['/f']));
      expectSyncDecline(() => rawCall(h, PathOp.iterdir, ['/f']));
    });

    test('overlayFsHandler: a miss in scratch falls through to base', () {
      final h = overlayFsHandler(
        base: answering(const MontyString('from-base')),
        scratch: notFound(),
      );

      expect(
        rawCall(h, PathOp.readText, ['/f']),
        const MontyString('from-base'),
      );
    });

    test('overlayFsHandler: base-only unlink is refused synchronously', () {
      final h = overlayFsHandler(
        base: answering(const MontyBool(true)),
        scratch: notFound(),
      );

      expect(
        () => rawCall(h, PathOp.unlink, ['/f']),
        throwsA(
          isA<ExternalException>().having(
            (e) => e.excType,
            'excType',
            'PermissionError',
          ),
        ),
      );
    });

    test('overlayFsHandler: Future-returning layers still work', () async {
      OsHandler later(FutureOr<MontyValue> Function() body) =>
          (operation, args, kwargs) async => body();
      final h = overlayFsHandler(
        base: later(() => const MontyString('base-later')),
        scratch: later(
          () => throw const ExternalException('FileNotFoundError', 'gone'),
        ),
      );

      final read = rawCall(h, PathOp.readText, ['/f']);
      expect(read, isA<Future<MontyValue>>());
      expect(await read, const MontyString('base-later'));
    });

    test('overlayFsHandler: a Future miss then a base decline', () async {
      final h = overlayFsHandler(
        base: declining(),
        scratch: (operation, args, kwargs) async =>
            throw const ExternalException('FileNotFoundError', 'gone'),
      );

      // The decline comes after an awaited miss, so it cannot be synchronous:
      // it fails the Future, which is what core reports as a TypeError.
      final result = rawCall(h, PathOp.readText, ['/f']);
      expect(result, isA<Future<MontyValue>>());
      await expectLater(result, throwsA(isA<OsCallNotHandledException>()));
    });

    test('overlayFsHandler over composed handlers', () {
      final h = overlayFsHandler(
        base: composeOsHandlers({'Path.': fsHandler(MemoryFileSystem())}),
        scratch: composeOsHandlers({'Path.': fsHandler(MemoryFileSystem())}),
      );

      expectSyncDecline(() => rawCall(h, 'socket.connect'));
      expectSyncDecline(() => rawCall(h, 'Path.stat', ['/a']));
    });
  });
}
