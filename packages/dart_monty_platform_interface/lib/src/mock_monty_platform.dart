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
  /// Creates a [MockMontyPlatform].
  MockMontyPlatform();

  // ---------------------------------------------------------------------------
  // Config (what to return)
  // ---------------------------------------------------------------------------

  /// The result returned by [run].
  ///
  /// Must be set before calling [run] or a [StateError] is thrown.
  MontyResult? runResult;

  /// The snapshot data returned by [snapshot].
  ///
  /// Must be set before calling [snapshot] or a [StateError] is thrown.
  Uint8List? snapshotData;

  /// The platform instance returned by [restore].
  ///
  /// Must be set before calling [restore] or a [StateError] is thrown.
  MontyPlatform? restoreResult;

  /// Whether [dispose] has been called.
  bool isDisposed = false;

  // ---------------------------------------------------------------------------
  // Invocation history (what was called)
  // ---------------------------------------------------------------------------

  /// Codes passed to [run], in call order.
  final List<String> runCodes = [];

  /// Inputs passed to [run], in call order.
  final List<Map<String, Object?>?> runInputsList = [];

  /// Limits passed to [run], in call order.
  final List<MontyLimits?> runLimitsList = [];

  /// Script names passed to [run], in call order.
  final List<String?> runScriptNamesList = [];

  /// Codes passed to [start], in call order.
  final List<String> startCodes = [];

  /// Inputs passed to [start], in call order.
  final List<Map<String, Object?>?> startInputsList = [];

  /// External functions passed to [start], in call order.
  final List<List<String>?> startExternalFunctionsList = [];

  /// Limits passed to [start], in call order.
  final List<MontyLimits?> startLimitsList = [];

  /// Script names passed to [start], in call order.
  final List<String?> startScriptNamesList = [];

  /// Return values passed to [resume], in call order.
  final List<Object?> resumeReturnValues = [];

  /// Error messages passed to [resumeWithError], in call order.
  final List<String> resumeErrorMessages = [];

  /// Call count for [resumeAsFuture], in call order.
  int resumeAsFutureCount = 0;

  /// Results passed to [resolveFutures], in call order.
  final List<Map<int, Object?>> resolveFuturesResultsList = [];

  /// Errors passed to [resolveFutures], in call order.
  final List<Map<int, String>?> resolveFuturesErrorsList = [];

  /// Snapshot data passed to [restore], in call order.
  final List<Uint8List> restoreDataList = [];

  final Queue<MontyProgress> _progressQueue = Queue<MontyProgress>();

  // ---------------------------------------------------------------------------
  // Convenience getters (most recent call)
  // ---------------------------------------------------------------------------

  /// The code passed to the most recent [run] call.
  String? get lastRunCode => runCodes.isEmpty ? null : runCodes.last;

  /// The inputs passed to the most recent [run] call.
  Map<String, Object?>? get lastRunInputs =>
      runInputsList.isEmpty ? null : runInputsList.last;

  /// The limits passed to the most recent [run] call.
  MontyLimits? get lastRunLimits =>
      runLimitsList.isEmpty ? null : runLimitsList.last;

  /// The script name passed to the most recent [run] call.
  String? get lastRunScriptName =>
      runScriptNamesList.isEmpty ? null : runScriptNamesList.last;

  /// The code passed to the most recent [start] call.
  String? get lastStartCode => startCodes.isEmpty ? null : startCodes.last;

  /// The inputs passed to the most recent [start] call.
  Map<String, Object?>? get lastStartInputs =>
      startInputsList.isEmpty ? null : startInputsList.last;

  /// The external functions passed to the most recent [start] call.
  List<String>? get lastStartExternalFunctions =>
      startExternalFunctionsList.isEmpty
          ? null
          : startExternalFunctionsList.last;

  /// The limits passed to the most recent [start] call.
  MontyLimits? get lastStartLimits =>
      startLimitsList.isEmpty ? null : startLimitsList.last;

  /// The script name passed to the most recent [start] call.
  String? get lastStartScriptName =>
      startScriptNamesList.isEmpty ? null : startScriptNamesList.last;

  /// The return value passed to the most recent [resume] call.
  Object? get lastResumeReturnValue =>
      resumeReturnValues.isEmpty ? null : resumeReturnValues.last;

  /// The error message passed to the most recent [resumeWithError] call.
  String? get lastResumeErrorMessage =>
      resumeErrorMessages.isEmpty ? null : resumeErrorMessages.last;

  /// The results passed to the most recent [resolveFutures] call.
  Map<int, Object?>? get lastResolveFuturesResults =>
      resolveFuturesResultsList.isEmpty ? null : resolveFuturesResultsList.last;

  /// The errors passed to the most recent [resolveFutures] call.
  Map<int, String>? get lastResolveFuturesErrors =>
      resolveFuturesErrorsList.isEmpty ? null : resolveFuturesErrorsList.last;

  /// The snapshot data passed to the most recent [restore] call.
  Uint8List? get lastRestoreData =>
      restoreDataList.isEmpty ? null : restoreDataList.last;

  /// Adds a [MontyProgress] to the FIFO queue consumed by [start],
  /// [resume], [resumeWithError], [resumeAsFuture], and
  /// [resolveFutures].
  void enqueueProgress(MontyProgress progress) {
    _progressQueue.add(progress);
  }

  @override
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final result = runResult;
    if (result == null) {
      throw StateError(
        'runResult not set. Assign a MontyResult before calling run().',
      );
    }
    runCodes.add(code);
    runInputsList.add(inputs);
    runLimitsList.add(limits);
    runScriptNamesList.add(scriptName);

    return result;
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    startCodes.add(code);
    startInputsList.add(inputs);
    startExternalFunctionsList.add(externalFunctions);
    startLimitsList.add(limits);
    startScriptNamesList.add(scriptName);

    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    resumeReturnValues.add(returnValue);

    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    resumeErrorMessages.add(errorMessage);

    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    resumeAsFutureCount++;

    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    resolveFuturesResultsList.add(results);
    resolveFuturesErrorsList.add(errors);

    return _dequeueProgress();
  }

  @override
  Future<Uint8List> snapshot() async {
    final data = snapshotData;
    if (data == null) {
      throw StateError(
        'snapshotData not set. Assign a Uint8List before calling snapshot().',
      );
    }

    return data;
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    final platform = restoreResult;
    if (platform == null) {
      throw StateError(
        'restoreResult not set. Assign a MontyPlatform before calling '
        'restore().',
      );
    }
    restoreDataList.add(data);

    return platform;
  }

  @override
  Future<void> dispose() async {
    isDisposed = true;
  }

  MontyProgress _dequeueProgress() {
    if (_progressQueue.isEmpty) {
      throw StateError(
        'No progress enqueued. Call enqueueProgress() before '
        'start(), resume(), resumeWithError(), resumeAsFuture(), '
        'or resolveFutures().',
      );
    }

    return _progressQueue.removeFirst();
  }
}
