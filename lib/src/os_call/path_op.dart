/// String constants for `Path.*` OS call operation names.
///
/// Use these instead of raw string literals in `OsProvider` switch statements
/// to get IDE autocomplete and typo safety without introducing a parse step
/// at the Rust→Dart protocol boundary.
///
/// ```dart
/// return switch (call.operationName) {
///   PathOp.readText => _readText(args),
///   PathOp.writeText => _writeText(args),
///   _ => throw UnsupportedError('Unsupported: ${call.operationName}'),
/// };
/// ```
abstract final class PathOp {
  /// `Path.exists`
  static const exists = 'Path.exists';

  /// `Path.is_file`
  static const isFile = 'Path.is_file';

  /// `Path.is_dir`
  static const isDir = 'Path.is_dir';

  /// `Path.is_symlink`
  static const isSymlink = 'Path.is_symlink';

  /// `Path.read_text`
  static const readText = 'Path.read_text';

  /// `Path.read_bytes`
  static const readBytes = 'Path.read_bytes';

  /// `Path.write_text`
  static const writeText = 'Path.write_text';

  /// `Path.write_bytes`
  static const writeBytes = 'Path.write_bytes';

  /// `Path.append_text` (`open(..., 'a')` then write)
  static const appendText = 'Path.append_text';

  /// `Path.append_bytes` (`open(..., 'ab')` then write)
  static const appendBytes = 'Path.append_bytes';

  /// `open` — the `open()` builtin's OS-call (no `Path.` prefix). Carries
  /// `[path, mode]`; the host returns a `MontyFileHandle`.
  ///
  /// **Renamed in monty v0.0.19: was `'Open'`.** It was the only capitalised,
  /// undotted op, so the new spelling is consistent with `Path.*`, `os.*`,
  /// `date.*` and `datetime.*`. The break is silent — a handler still matching
  /// `'Open'` simply stops matching and falls through, with no error — so
  /// always compare against this constant rather than a string literal.
  static const open = 'open';

  /// `Path.mkdir`
  static const mkdir = 'Path.mkdir';

  /// `Path.unlink`
  static const unlink = 'Path.unlink';

  /// `Path.rmdir`
  static const rmdir = 'Path.rmdir';

  /// `Path.rename`
  static const rename = 'Path.rename';

  /// `Path.iterdir`
  static const iterdir = 'Path.iterdir';

  /// `Path.resolve`
  static const resolve = 'Path.resolve';

  /// `Path.absolute`
  static const absolute = 'Path.absolute';
}
