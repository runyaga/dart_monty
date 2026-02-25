import 'dart:typed_data';

import 'package:dart_monty_ffi/src/native_bindings.dart';

const _defaultCompleteJson =
    '{"value": null, "usage": {"memory_bytes_used": 0, '
    '"time_elapsed_ms": 0, "stack_depth_used": 0}}';

/// A hand-written mock of [NativeBindings] with configurable returns
/// and call tracking.
///
/// Configure return values via the `next*` fields, then call the methods.
/// After each call, the invocation is recorded in the `*Calls` lists.
class MockNativeBindings extends NativeBindings {
  // ---------------------------------------------------------------------------
  // Next return values (configure before calling)
  // ---------------------------------------------------------------------------

  /// Handle address returned by [create]. Defaults to 42.
  int nextCreateHandle = 42;

  /// If non-null, [create] throws this message as a [StateError].
  String? nextCreateError;

  /// Result returned by [run].
  RunResult nextRunResult = const RunResult(
    tag: 0,
    resultJson: '{"value": 4, "usage": {"memory_bytes_used": 0, '
        '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
  );

  /// Result returned by [start].
  ProgressResult nextStartResult = const ProgressResult(
    tag: 0,
    resultJson: _defaultCompleteJson,
  );

  /// Queue of results returned by [resume]. Dequeues on each call.
  final List<ProgressResult> resumeResults = [];

  /// Queue of results returned by [resumeWithError]. Dequeues on each call.
  final List<ProgressResult> resumeWithErrorResults = [];

  /// Queue of results returned by [resumeAsFuture]. Dequeues on each call.
  final List<ProgressResult> resumeAsFutureResults = [];

  /// Queue of results returned by [resolveFutures]. Dequeues on each call.
  final List<ProgressResult> resolveFuturesResults = [];

  /// Data returned by [snapshot].
  Uint8List nextSnapshotData = Uint8List.fromList([1, 2, 3]);

  /// Handle address returned by [restore]. Defaults to 99.
  int nextRestoreHandle = 99;

  /// If non-null, [restore] throws this message as a [StateError].
  String? nextRestoreError;

  // ---------------------------------------------------------------------------
  // Call tracking
  // ---------------------------------------------------------------------------

  /// Records of `(code, externalFunctions, scriptName)` passed to [create].
  final List<({String code, String? externalFunctions, String? scriptName})>
      createCalls = [];

  /// Handle addresses passed to [free].
  final List<int> freeCalls = [];

  /// Handle addresses passed to [run].
  final List<int> runCalls = [];

  /// Handle addresses passed to [start].
  final List<int> startCalls = [];

  /// Records of `(handle, valueJson)` passed to [resume].
  final List<({int handle, String valueJson})> resumeCalls = [];

  /// Records of `(handle, errorMessage)` passed to [resumeWithError].
  final List<({int handle, String errorMessage})> resumeWithErrorCalls = [];

  /// Handle addresses passed to [resumeAsFuture].
  final List<int> resumeAsFutureCalls = [];

  /// Records of `(handle, resultsJson, errorsJson)` passed to
  /// [resolveFutures].
  final List<({int handle, String resultsJson, String errorsJson})>
      resolveFuturesCalls = [];

  /// Records of `(handle, bytes)` passed to [setMemoryLimit].
  final List<({int handle, int bytes})> setMemoryLimitCalls = [];

  /// Records of `(handle, ms)` passed to [setTimeLimitMs].
  final List<({int handle, int ms})> setTimeLimitMsCalls = [];

  /// Records of `(handle, depth)` passed to [setStackLimit].
  final List<({int handle, int depth})> setStackLimitCalls = [];

  /// Handle addresses passed to [snapshot].
  final List<int> snapshotCalls = [];

  /// Snapshot data passed to [restore].
  final List<Uint8List> restoreCalls = [];

  // ---------------------------------------------------------------------------
  // Implementation
  // ---------------------------------------------------------------------------

  @override
  int create(String code, {String? externalFunctions, String? scriptName}) {
    createCalls.add(
      (
        code: code,
        externalFunctions: externalFunctions,
        scriptName: scriptName
      ),
    );
    final createError = nextCreateError;
    if (createError != null) {
      throw StateError(createError);
    }

    return nextCreateHandle;
  }

  @override
  void free(int handle) {
    freeCalls.add(handle);
  }

  @override
  RunResult run(int handle) {
    runCalls.add(handle);

    return nextRunResult;
  }

  @override
  ProgressResult start(int handle) {
    startCalls.add(handle);

    return nextStartResult;
  }

  @override
  ProgressResult resume(int handle, String valueJson) {
    resumeCalls.add((handle: handle, valueJson: valueJson));
    if (resumeResults.isNotEmpty) return resumeResults.removeAt(0);

    return const ProgressResult(
      tag: 0,
      resultJson: _defaultCompleteJson,
    );
  }

  @override
  ProgressResult resumeWithError(int handle, String errorMessage) {
    resumeWithErrorCalls.add(
      (handle: handle, errorMessage: errorMessage),
    );
    if (resumeWithErrorResults.isNotEmpty) {
      return resumeWithErrorResults.removeAt(0);
    }

    return const ProgressResult(
      tag: 0,
      resultJson: _defaultCompleteJson,
    );
  }

  @override
  ProgressResult resumeAsFuture(int handle) {
    resumeAsFutureCalls.add(handle);
    if (resumeAsFutureResults.isNotEmpty) {
      return resumeAsFutureResults.removeAt(0);
    }

    return const ProgressResult(
      tag: 3,
      futureCallIdsJson: '[0]',
    );
  }

  @override
  ProgressResult resolveFutures(
    int handle,
    String resultsJson,
    String errorsJson,
  ) {
    resolveFuturesCalls.add(
      (handle: handle, resultsJson: resultsJson, errorsJson: errorsJson),
    );
    if (resolveFuturesResults.isNotEmpty) {
      return resolveFuturesResults.removeAt(0);
    }

    return const ProgressResult(
      tag: 0,
      resultJson: _defaultCompleteJson,
    );
  }

  @override
  void setMemoryLimit(int handle, int bytes) {
    setMemoryLimitCalls.add((handle: handle, bytes: bytes));
  }

  @override
  void setTimeLimitMs(int handle, int ms) {
    setTimeLimitMsCalls.add((handle: handle, ms: ms));
  }

  @override
  void setStackLimit(int handle, int depth) {
    setStackLimitCalls.add((handle: handle, depth: depth));
  }

  @override
  Uint8List snapshot(int handle) {
    snapshotCalls.add(handle);

    return nextSnapshotData;
  }

  @override
  int restore(Uint8List data) {
    restoreCalls.add(data);
    final restoreError = nextRestoreError;
    if (restoreError != null) {
      throw StateError(restoreError);
    }

    return nextRestoreHandle;
  }
}
