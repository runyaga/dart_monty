import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';

/// Write operations that are blocked in read-only mode.
const _writeOps = {
  'Path.write_text',
  'Path.write_bytes',
  'Path.mkdir',
  'Path.unlink',
  'Path.rmdir',
  'Path.rename',
};

/// Wraps any [OsProvider] and blocks write operations.
///
/// Read operations, environment access, and datetime pass through unchanged.
/// Write operations throw [OsCallPermissionError].
///
/// ```dart
/// final ro = ReadOnlyOsProvider(
///   FileSystemOsProvider(const LocalFileSystem()),
/// );
/// final monty = Monty(os: OsProvider.compose({
///   'Path.': ro,
///   'date.': TimeOsProvider(),
/// }));
/// ```
///
/// All `date.*`, `datetime.*`, and `os.*` operations pass through unchanged.
class ReadOnlyOsProvider extends OsProvider {
  /// Creates a read-only wrapper around the given provider.
  const ReadOnlyOsProvider(this._inner) : super.base();

  final OsProvider _inner;

  @override
  Future<Object?> resolve(MontyOsCall call) {
    if (_writeOps.contains(call.operationName)) {
      throw OsCallPermissionError(
        call.operationName,
        'Read-only filesystem',
      );
    }

    return _inner.resolve(call);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
