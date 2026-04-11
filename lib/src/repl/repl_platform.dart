import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/repl/monty_repl.dart';

/// Adapts [MontyRepl] to the [MontyPlatform] interface.
///
/// This allows `MontyRepl` to be used with `DefaultMontyBridge` and the
/// full plugin dispatch system. The bridge's dispatch loop calls
/// [start]/[resume]/[resumeWithError], which delegate to the REPL's
/// [MontyRepl.feedStart]/[MontyRepl.resume]/[MontyRepl.resumeWithError].
///
/// Unlike one-shot [MontyPlatform] implementations, the REPL persists
/// heap state (variables, functions, classes) across calls.
class ReplPlatform implements MontyPlatform {
  /// Creates a [ReplPlatform] wrapping [repl].
  ReplPlatform({required MontyRepl repl}) : _repl = repl;

  final MontyRepl _repl;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) => _repl.feed(code);

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) => _repl.feedStart(code, externalFunctions: externalFunctions);

  @override
  Future<MontyProgress> resume(Object? returnValue) =>
      _repl.resume(returnValue);

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _repl.resumeWithError(errorMessage);

  @override
  Future<void> dispose() => _repl.dispose();
}
