import 'dart:typed_data';

import 'package:dart_monty_desktop/src/desktop_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// A hand-written mock of [DesktopBindings] with configurable returns
/// and call tracking.
///
/// Configure return values via the `next*` fields, then call the methods.
/// After each call, the invocation is recorded in the `*Calls` lists.
class MockDesktopBindings extends DesktopBindings {
  // ---------------------------------------------------------------------------
  // Next return values (configure before calling)
  // ---------------------------------------------------------------------------

  /// Whether [init] returns success. Defaults to `true`.
  bool nextInitResult = true;

  /// Result returned by [run].
  DesktopRunResult nextRunResult = const DesktopRunResult(
    result: MontyResult(
      value: 4,
      usage: _zeroUsage,
    ),
  );

  /// Result returned by [start].
  DesktopProgressResult nextStartResult = const DesktopProgressResult(
    progress: MontyComplete(
      result: MontyResult(usage: _zeroUsage),
    ),
  );

  /// Queue of results returned by [resume]. Dequeues on each call.
  final List<DesktopProgressResult> resumeResults = [];

  /// Queue of results returned by [resumeWithError]. Dequeues on each call.
  final List<DesktopProgressResult> resumeWithErrorResults = [];

  /// Data returned by [snapshot].
  Uint8List nextSnapshotData = Uint8List.fromList([1, 2, 3]);

  /// If non-null, [snapshot] throws this as a [MontyException].
  String? nextSnapshotError;

  /// If non-null, [restore] throws this as a [MontyException].
  String? nextRestoreError;

  /// If non-null, [dispose] throws this as a [MontyException].
  String? nextDisposeError;

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

  // ---------------------------------------------------------------------------
  // Implementation
  // ---------------------------------------------------------------------------

  @override
  Future<bool> init() async {
    initCalls++;
    return nextInitResult;
  }

  @override
  Future<DesktopRunResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    runCalls.add((code: code, limits: limits, scriptName: scriptName));
    return nextRunResult;
  }

  @override
  Future<DesktopProgressResult> start(
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
  Future<DesktopProgressResult> resume(Object? returnValue) async {
    resumeCalls.add(returnValue);
    if (resumeResults.isNotEmpty) return resumeResults.removeAt(0);
    return const DesktopProgressResult(
      progress: MontyComplete(
        result: MontyResult(usage: _zeroUsage),
      ),
    );
  }

  @override
  Future<DesktopProgressResult> resumeWithError(String errorMessage) async {
    resumeWithErrorCalls.add(errorMessage);
    if (resumeWithErrorResults.isNotEmpty) {
      return resumeWithErrorResults.removeAt(0);
    }
    return const DesktopProgressResult(
      progress: MontyComplete(
        result: MontyResult(usage: _zeroUsage),
      ),
    );
  }

  @override
  Future<Uint8List> snapshot() async {
    snapshotCalls++;
    if (nextSnapshotError != null) {
      throw MontyException(message: nextSnapshotError!);
    }
    return nextSnapshotData;
  }

  @override
  Future<void> restore(Uint8List data) async {
    restoreCalls.add(data);
    if (nextRestoreError != null) {
      throw MontyException(message: nextRestoreError!);
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (nextDisposeError != null) {
      throw MontyException(message: nextDisposeError!);
    }
  }

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );
}
