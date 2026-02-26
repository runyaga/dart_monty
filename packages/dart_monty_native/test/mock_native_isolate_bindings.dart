import 'dart:typed_data';

import 'package:dart_monty_native/src/native_isolate_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// A hand-written mock of [NativeIsolateBindings] with configurable returns
/// and call tracking.
///
/// Configure return values via the `next*` fields, then call the methods.
/// After each call, the invocation is recorded in the `*Calls` lists.
class MockNativeIsolateBindings extends NativeIsolateBindings {
  // ---------------------------------------------------------------------------
  // Next return values (configure before calling)
  // ---------------------------------------------------------------------------

  /// Whether [init] returns success. Defaults to `true`.
  bool nextInitResult = true;

  /// Result returned by [run].
  MontyResult nextRunResult = const MontyResult(
    value: 4,
    usage: _zeroUsage,
  );

  /// Result returned by [start].
  MontyProgress nextStartResult = const MontyComplete(
    result: MontyResult(usage: _zeroUsage),
  );

  /// Queue of results returned by [resume]. Dequeues on each call.
  final List<MontyProgress> resumeResults = [];

  /// Queue of results returned by [resumeWithError]. Dequeues on each call.
  final List<MontyProgress> resumeWithErrorResults = [];

  /// Data returned by [snapshot].
  Uint8List nextSnapshotData = Uint8List.fromList([1, 2, 3]);

  /// If non-null, [snapshot] throws this as a [MontyException].
  String? nextSnapshotError;

  /// If non-null, [restore] throws this as a [MontyException].
  String? nextRestoreError;

  /// If non-null, [dispose] throws this as a [MontyException].
  String? nextDisposeError;

  /// Queue of results returned by [resumeAsFuture]. Dequeues on each call.
  final List<MontyProgress> resumeAsFutureResults = [];

  /// Queue of results returned by [resolveFutures]. Dequeues on each call.
  final List<MontyProgress> resolveFuturesResults = [];

  // ---------------------------------------------------------------------------
  // Call tracking
  // ---------------------------------------------------------------------------

  /// Number of times [init] was called.
  int initCalls = 0;

  /// Records of `(code, limits, scriptName)` passed to [run].
  final List<({String code, MontyLimits? limits, String? scriptName})>
      runCalls = [];

  /// Records of `(code, externalFunctions, limits, scriptName)` passed to
  /// [start].
  final List<
      ({
        String code,
        List<String>? externalFunctions,
        MontyLimits? limits,
        String? scriptName,
      })> startCalls = [];

  /// Records of `returnValue` passed to [resume].
  final List<Object?> resumeCalls = [];

  /// Records of `errorMessage` passed to [resumeWithError].
  final List<String> resumeWithErrorCalls = [];

  /// Number of times [snapshot] was called.
  int snapshotCalls = 0;

  /// Records of snapshot data passed to [restore].
  final List<Uint8List> restoreCalls = [];

  /// Number of times [dispose] was called.
  int disposeCalls = 0;

  /// Number of times [resumeAsFuture] was called.
  int resumeAsFutureCalls = 0;

  /// Records of results passed to [resolveFutures].
  final List<Map<int, Object?>> resolveFuturesCalls = [];

  /// Records of errors passed to [resolveFutures], in call order.
  final List<Map<int, String>?> resolveFuturesErrorsCalls = [];

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  // ---------------------------------------------------------------------------
  // Implementation
  // ---------------------------------------------------------------------------

  @override
  Future<bool> init() async {
    initCalls++;

    return nextInitResult;
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    runCalls.add((code: code, limits: limits, scriptName: scriptName));

    return nextRunResult;
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    startCalls.add(
      (
        code: code,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      ),
    );

    return nextStartResult;
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    resumeCalls.add(returnValue);
    if (resumeResults.isNotEmpty) return resumeResults.removeAt(0);

    return const MontyComplete(
      result: MontyResult(usage: _zeroUsage),
    );
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    resumeWithErrorCalls.add(errorMessage);
    if (resumeWithErrorResults.isNotEmpty) {
      return resumeWithErrorResults.removeAt(0);
    }

    return const MontyComplete(
      result: MontyResult(usage: _zeroUsage),
    );
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    resumeAsFutureCalls++;
    if (resumeAsFutureResults.isNotEmpty) {
      return resumeAsFutureResults.removeAt(0);
    }

    return const MontyResolveFutures(pendingCallIds: [0]);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    resolveFuturesCalls.add(results);
    resolveFuturesErrorsCalls.add(errors);
    if (resolveFuturesResults.isNotEmpty) {
      return resolveFuturesResults.removeAt(0);
    }

    return const MontyComplete(
      result: MontyResult(usage: _zeroUsage),
    );
  }

  @override
  Future<Uint8List> snapshot() async {
    snapshotCalls++;
    final error = nextSnapshotError;
    if (error != null) {
      throw MontyException(message: error);
    }

    return nextSnapshotData;
  }

  @override
  Future<void> restore(Uint8List data) async {
    restoreCalls.add(data);
    final error = nextRestoreError;
    if (error != null) {
      throw MontyException(message: error);
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    final error = nextDisposeError;
    if (error != null) {
      throw MontyException(message: error);
    }
  }
}
