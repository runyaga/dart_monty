import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyPath;

/// The REPL's Python state and writable, session-local memory filesystem.
/// The caller owns the pool and must dispose this session before closing it.
final class ReplDemoSession {
  ReplDemoSession._(this._pool);

  final Monty _pool;

  /// The current runtime, replaced by [reset].
  late MontyRuntime runtime;

  /// Starts an empty REPL with `/work` as its working directory.
  static Future<ReplDemoSession> start(Monty pool) async {
    final session = ReplDemoSession._(pool);
    session.runtime = await session._newRuntime();

    return session;
  }

  Future<MontyRuntime> _newRuntime() async {
    final files = OSAccess();
    await files.call('Path.mkdir', [MontyPath('/work')], {});
    final next = await MontyRuntime.start(pool: _pool, os: files.call);
    try {
      await next.execute("import os\nos.chdir('/work')").result;

      return next;
    } on Object {
      await next.dispose();
      rethrow;
    }
  }

  /// Clears Python globals and all files, returning to `/work`.
  Future<void> reset() async {
    await runtime.dispose();
    runtime = await _newRuntime();
  }

  /// Releases the runtime; the caller still owns the pool.
  Future<void> dispose() => runtime.dispose();
}
