import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';

/// A mock implementation of [MontyPlatform] for testing.
///
/// Configure expected return values before calling methods:
/// ```dart
/// final mock = MockMontyPlatform();
/// mock.runResult = MontyResult(value: 42, usage: usage);
/// final result = await mock.run('1 + 1');
/// expect(mock.lastRunCode, '1 + 1');
/// ```
///
/// For [start], [resume], and [resumeWithError], enqueue progress values
/// using [enqueueProgress]:
/// ```dart
/// mock.enqueueProgress(MontyPending(functionName: 'fetch', arguments: []));
/// mock.enqueueProgress(MontyComplete(result: result));
/// ```
class MockMontyPlatform extends MontyPlatform {
  /// The result returned by [run].
  ///
  /// Must be set before calling [run] or a [StateError] is thrown.
  MontyResult? runResult;

  final Queue<MontyProgress> _progressQueue = Queue<MontyProgress>();

  /// The snapshot data returned by [snapshot].
  ///
  /// Must be set before calling [snapshot] or a [StateError] is thrown.
  Uint8List? snapshotData;

  /// The platform instance returned by [restore].
  ///
  /// Must be set before calling [restore] or a [StateError] is thrown.
  MontyPlatform? restoreResult;

  /// The code passed to the last [run] call.
  String? lastRunCode;

  /// The inputs passed to the last [run] call.
  Map<String, Object?>? lastRunInputs;

  /// The limits passed to the last [run] call.
  MontyLimits? lastRunLimits;

  /// The code passed to the last [start] call.
  String? lastStartCode;

  /// The inputs passed to the last [start] call.
  Map<String, Object?>? lastStartInputs;

  /// The external functions passed to the last [start] call.
  List<String>? lastStartExternalFunctions;

  /// The limits passed to the last [start] call.
  MontyLimits? lastStartLimits;

  /// The return value passed to the last [resume] call.
  Object? lastResumeReturnValue;

  /// The error message passed to the last [resumeWithError] call.
  String? lastResumeErrorMessage;

  /// The snapshot data passed to the last [restore] call.
  Uint8List? lastRestoreData;

  /// Whether [dispose] has been called.
  bool isDisposed = false;

  /// Adds a [MontyProgress] to the FIFO queue consumed by [start],
  /// [resume], and [resumeWithError].
  void enqueueProgress(MontyProgress progress) {
    _progressQueue.add(progress);
  }

  MontyProgress _dequeueProgress() {
    if (_progressQueue.isEmpty) {
      throw StateError(
        'No progress enqueued. Call enqueueProgress() before '
        'start(), resume(), or resumeWithError().',
      );
    }
    return _progressQueue.removeFirst();
  }

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
  }) async {
    if (runResult == null) {
      throw StateError(
        'runResult not set. Assign a MontyResult before calling run().',
      );
    }
    lastRunCode = code;
    lastRunInputs = inputs;
    lastRunLimits = limits;
    return runResult!;
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
  }) async {
    lastStartCode = code;
    lastStartInputs = inputs;
    lastStartExternalFunctions = externalFunctions;
    lastStartLimits = limits;
    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    lastResumeReturnValue = returnValue;
    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    lastResumeErrorMessage = errorMessage;
    return _dequeueProgress();
  }

  @override
  Future<Uint8List> snapshot() async {
    if (snapshotData == null) {
      throw StateError(
        'snapshotData not set. Assign a Uint8List before calling snapshot().',
      );
    }
    return snapshotData!;
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    if (restoreResult == null) {
      throw StateError(
        'restoreResult not set. Assign a MontyPlatform before calling '
        'restore().',
      );
    }
    lastRestoreData = data;
    return restoreResult!;
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
  }
}
