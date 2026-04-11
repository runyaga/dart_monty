import 'package:dart_monty/src/platform/core_bindings.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/repl/repl_bindings.dart';
import 'package:dart_monty/src/wasm/wasm_bindings.dart';

/// WASM implementation of [ReplBindings].
///
/// Manages a persistent REPL session inside a Web Worker via
/// [WasmBindings].
class WasmReplBindings implements ReplBindings {
  /// Creates [WasmReplBindings] backed by [bindings].
  WasmReplBindings({required WasmBindings bindings}) : _bindings = bindings;

  final WasmBindings _bindings;
  bool _created = false;

  @override
  Future<void> create({String? scriptName}) async {
    await _bindings.replCreate(scriptName: scriptName);
    _created = true;
  }

  @override
  Future<CoreRunResult> feedRun(String code) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replFeedRun(code);

    return _translateWasmResult(result);
  }

  @override
  Future<int> detectContinuation(String source) async {
    return _bindings.replDetectContinuation(source);
  }

  @override
  void setExtFns(List<String> names) {
    // WASM implementation deferred to Phase 2b.
    throw UnimplementedError('REPL setExtFns not yet available on WASM');
  }

  @override
  Future<CoreProgressResult> feedStart(String code) {
    throw UnimplementedError('REPL feedStart not yet available on WASM');
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) {
    throw UnimplementedError('REPL resume not yet available on WASM');
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) {
    throw UnimplementedError('REPL resumeWithError not yet available on WASM');
  }

  @override
  Future<void> dispose() async {
    if (!_created) return;
    await _bindings.replFree();
    _created = false;
  }

  // -----------------------------------------------------------------------
  // Translation (same logic as WasmCoreBindings._translateRunResult)
  // -----------------------------------------------------------------------

  CoreRunResult _translateWasmResult(WasmRunResult result) {
    if (result.ok) {
      return CoreRunResult(
        ok: true,
        value: result.value,
        usage: const MontyResourceUsage(
          memoryBytesUsed: 0,
          timeElapsedMs: 0,
          stackDepthUsed: 0,
        ),
        printOutput: result.printOutput,
      );
    }

    return CoreRunResult(
      ok: false,
      error: result.error,
      excType: result.excType,
      traceback: result.traceback,
      filename: result.filename,
      lineNumber: result.lineNumber,
      columnNumber: result.columnNumber,
      sourceCode: result.sourceCode,
    );
  }
}
