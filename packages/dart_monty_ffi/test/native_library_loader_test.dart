import 'dart:io' show Platform;

import 'package:dart_monty_ffi/src/native_library_loader.dart';
import 'package:test/test.dart';

void main() {
  group('NativeLibraryLoader.resolve', () {
    test('returns override path when provided', () {
      final path = NativeLibraryLoader.resolve(
        overridePath: '/custom/path/libmonty.dylib',
      );

      expect(path, '/custom/path/libmonty.dylib');
    });

    test('returns platform default when no override', () {
      final path = NativeLibraryLoader.resolve();

      if (Platform.isMacOS || Platform.isIOS) {
        expect(path, 'libdart_monty_native.dylib');
      } else if (Platform.isLinux || Platform.isAndroid) {
        expect(path, 'libdart_monty_native.so');
      } else if (Platform.isWindows) {
        expect(path, 'dart_monty_native.dll');
      }
    });

    test('override path takes precedence over env var', () {
      // Even if DART_MONTY_LIB_PATH is set, overridePath wins.
      final path = NativeLibraryLoader.resolve(
        overridePath: '/my/lib.dylib',
      );

      expect(path, '/my/lib.dylib');
    });
  });
}
