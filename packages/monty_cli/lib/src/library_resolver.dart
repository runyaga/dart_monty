import 'dart:io';

/// Resolves the path to the native Monty shared library.
///
/// Priority:
/// 1. Explicit [override] (from `--library-path` flag)
/// 2. `MONTY_LIBRARY_PATH` environment variable
/// 3. `null` (fall back to default `DynamicLibrary.open` search)
String? resolveLibraryPath({String? override}) {
  if (override != null) return override;

  return Platform.environment['MONTY_LIBRARY_PATH'];
}
