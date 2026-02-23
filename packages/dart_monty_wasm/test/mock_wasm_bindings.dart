import 'dart:typed_data';

import 'package:dart_monty_wasm/src/wasm_bindings.dart';

/// A hand-written mock of [WasmBindings] with configurable returns
/// and call tracking.
///
/// Configure return values via the `next*` fields, then call the methods.
/// After each call, the invocation is recorded in the `*Calls` lists.
class MockWasmBindings extends WasmBindings {
  // ---------------------------------------------------------------------------
  // Next return values (configure before calling)
  // ---------------------------------------------------------------------------

  /// Whether [init] returns success. Defaults to `true`.
  bool nextInitResult = true;

  /// Result returned by [run].
  WasmRunResult nextRunResult = const WasmRunResult(ok: true, value: 4);

  /// Result returned by [start].
  WasmProgressResult nextStartResult = const WasmProgressResult(
    ok: true,
    state: 'complete',
  );

  /// Queue of results returned by [resume]. Dequeues on each call.
  final List<WasmProgressResult> resumeResults = [];

  /// Queue of results returned by [resumeWithError]. Dequeues on each call.
  final List<WasmProgressResult> resumeWithErrorResults = [];

  /// Data returned by [snapshot].
  Uint8List nextSnapshotData = Uint8List.fromList([1, 2, 3]);

  /// If non-null, [snapshot] throws this message as a [StateError].
  String? nextSnapshotError;

  /// If non-null, [restore] throws this message as a [StateError].
  String? nextRestoreError;

  /// Result returned by [discover].
  WasmDiscoverResult nextDiscoverResult = const WasmDiscoverResult(
    loaded: true,
    architecture: 'worker',
  );

  /// If non-null, [dispose] throws this message as a [StateError].
  String? nextDisposeError;

  // ---------------------------------------------------------------------------
  // Call tracking
  // ---------------------------------------------------------------------------

  /// Number of times [init] was called.
  int initCalls = 0;

  /// Records of `(code, limitsJson, scriptName)` passed to [run].
  final List<({String code, String? limitsJson, String? scriptName})> runCalls =
      [];

  /// Records of `(code, extFnsJson, limitsJson, scriptName)` passed to
  /// [start].
  final List<
      ({
        String code,
        String? extFnsJson,
        String? limitsJson,
        String? scriptName,
      })> startCalls = [];

  /// Records of `valueJson` passed to [resume].
  final List<String> resumeCalls = [];

  /// Records of `errorMessage` passed to [resumeWithError].
  final List<String> resumeWithErrorCalls = [];

  /// Number of times [snapshot] was called.
  int snapshotCalls = 0;

  /// Records of snapshot data passed to [restore].
  final List<Uint8List> restoreCalls = [];

  /// Number of times [discover] was called.
  int discoverCalls = 0;

  /// Number of times [dispose] was called.
  int disposeCalls = 0;

  // ---------------------------------------------------------------------------
  // Implementation
  // ---------------------------------------------------------------------------

  @override
  Future<bool> init() async {
    initCalls++;

    return nextInitResult;
  }

  @override
  Future<WasmRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    runCalls.add((code: code, limitsJson: limitsJson, scriptName: scriptName));

    return nextRunResult;
  }

  @override
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    startCalls.add(
      (
        code: code,
        extFnsJson: extFnsJson,
        limitsJson: limitsJson,
        scriptName: scriptName,
      ),
    );

    return nextStartResult;
  }

  @override
  Future<WasmProgressResult> resume(String valueJson) async {
    resumeCalls.add(valueJson);
    if (resumeResults.isNotEmpty) return resumeResults.removeAt(0);

    return const WasmProgressResult(
      ok: true,
      state: 'complete',
    );
  }

  @override
  Future<WasmProgressResult> resumeWithError(String errorMessage) async {
    resumeWithErrorCalls.add(errorMessage);
    if (resumeWithErrorResults.isNotEmpty) {
      return resumeWithErrorResults.removeAt(0);
    }

    return const WasmProgressResult(
      ok: true,
      state: 'complete',
    );
  }

  @override
  Future<WasmProgressResult> resumeAsFuture() async {
    throw UnsupportedError('resumeAsFuture() not supported in WASM');
  }

  @override
  Future<WasmProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    throw UnsupportedError('resolveFutures() not supported in WASM');
  }

  @override
  Future<Uint8List> snapshot() async {
    snapshotCalls++;
    final snapshotError = nextSnapshotError;
    if (snapshotError != null) {
      throw StateError(snapshotError);
    }

    return nextSnapshotData;
  }

  @override
  Future<void> restore(Uint8List data) async {
    restoreCalls.add(data);
    final restoreError = nextRestoreError;
    if (restoreError != null) {
      throw StateError(restoreError);
    }
  }

  @override
  Future<WasmDiscoverResult> discover() async {
    discoverCalls++;

    return nextDiscoverResult;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final disposeError = nextDisposeError;
    if (disposeError != null) {
      throw StateError(disposeError);
    }
  }
}
