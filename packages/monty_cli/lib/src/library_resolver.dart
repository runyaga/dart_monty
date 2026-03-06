import 'dart:io';

/// Resolves the path to the native Monty shared library.
///
/// Priority:
/// 1. Explicit [override] (from `--library-path` flag)
/// 2. `MONTY_LIBRARY_PATH` environment variable
/// 3. Co-located dylib next to the running executable
/// 4. `null` (fall back to default `DynamicLibrary.open` search)
String? resolveLibraryPath({String? override}) {
  if (override != null) return override;

  final envPath = Platform.environment['MONTY_LIBRARY_PATH'];
  if (envPath != null && envPath.isNotEmpty) return envPath;

  // Look for the dylib next to the executable.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final colocated = _colocatedPath(exeDir);
  if (colocated != null) return colocated;

  return null;
}

String? _colocatedPath(String dir) {
  final candidates = [
    '$dir/libdart_monty_native.dylib',
    '$dir/libdart_monty_native.so',
    '$dir/dart_monty_native.dll',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}
