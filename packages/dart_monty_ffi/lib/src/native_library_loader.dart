import 'dart:io' show Platform;

/// Resolves the platform-appropriate path for the native Monty shared library.
///
/// Supports macOS (`.dylib`), Linux (`.so`), and Windows (`.dll`).
/// The `DART_MONTY_LIB_PATH` environment variable overrides the default
/// library name when set.
abstract final class NativeLibraryLoader {
  /// The base library name without platform extension.
  static const _baseName = 'dart_monty_native';

  /// Returns the platform-appropriate shared library path.
  ///
  /// Resolution order:
  /// 1. [overridePath] parameter (for tests)
  /// 2. `DART_MONTY_LIB_PATH` environment variable
  /// 3. Platform default: `libdart_monty_native.dylib` / `.so` / `.dll`
  static String resolve({String? overridePath}) {
    if (overridePath != null) return overridePath;

    const envPath = String.fromEnvironment('DART_MONTY_LIB_PATH');
    if (envPath.isNotEmpty) return envPath;

    final envVar = Platform.environment['DART_MONTY_LIB_PATH'];
    if (envVar != null && envVar.isNotEmpty) return envVar;

    return _platformDefault();
  }

  static String _platformDefault() {
    if (Platform.isMacOS || Platform.isIOS) {
      return 'lib$_baseName.dylib';
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return 'lib$_baseName.so';
    }
    if (Platform.isWindows) {
      return '$_baseName.dll';
    }
    throw UnsupportedError(
      'Unsupported platform: ${Platform.operatingSystem}',
    );
  }
}
