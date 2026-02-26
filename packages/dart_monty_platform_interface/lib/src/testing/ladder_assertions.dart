import 'dart:convert';

import 'package:dart_monty_platform_interface/src/monty_exception.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:test/test.dart';

/// Asserts that [actual] matches the expected value in [fixture].
///
/// Supports three fixture keys:
/// - `expectedContains` — asserts `actual.toString()` contains the string.
/// - `expectedSorted` — sorts both sides before JSON comparison.
/// - `expected` — exact JSON equality.
void assertLadderResult(Object? actual, Map<String, dynamic> fixture) {
  final expectedContains = fixture['expectedContains'] as String?;
  if (expectedContains != null) {
    expect(
      actual.toString(),
      contains(expectedContains),
      reason: 'Fixture #${fixture['id']}: expected value to contain '
          '"$expectedContains", got: "$actual"',
    );

    return;
  }

  var expected = fixture['expected'];
  final expectedSorted = fixture['expectedSorted'] as bool? ?? false;

  var sortedActual = actual;
  if (expectedSorted) {
    if (actual is List) {
      sortedActual = [...actual]..sort((a, b) => '$a'.compareTo('$b'));
    }
    if (expected is List) {
      expected = [...expected]..sort((a, b) => '$a'.compareTo('$b'));
    }
  }

  expect(
    jsonEncode(sortedActual),
    jsonEncode(expected),
    reason: 'Fixture #${fixture['id']}: '
        'expected ${jsonEncode(expected)}, '
        'got ${jsonEncode(sortedActual)}',
  );
}

/// Asserts M7A fields on a [MontyPending] against fixture expectations.
///
/// Checks these fixture keys (all optional — missing keys are no-ops):
/// - `expectedFnName` — expected `functionName`
/// - `expectedArgs` — expected `arguments` (JSON equality)
/// - `expectedKwargs` — expected `kwargs` (null or map equality)
/// - `expectedCallIdNonZero` — asserts `callId != 0`
/// - `expectedMethodCall` — expected `methodCall` boolean
void assertPendingFields(MontyPending pending, Map<String, dynamic> fixture) {
  final expectedFnName = fixture['expectedFnName'] as String?;
  if (expectedFnName != null) {
    expect(
      pending.functionName,
      expectedFnName,
      reason: 'Fixture #${fixture['id']}: expected functionName '
          '"$expectedFnName", got: "${pending.functionName}"',
    );
  }

  final expectedArgs = fixture['expectedArgs'] as List?;
  if (expectedArgs != null) {
    expect(
      jsonEncode(pending.arguments),
      jsonEncode(expectedArgs),
      reason: 'Fixture #${fixture['id']}: expected args '
          '${jsonEncode(expectedArgs)}, got: ${jsonEncode(pending.arguments)}',
    );
  }

  final expectedKwargs = fixture['expectedKwargs'];
  if (fixture.containsKey('expectedKwargs')) {
    if (expectedKwargs == null) {
      expect(
        pending.kwargs,
        isNull,
        reason: 'Fixture #${fixture['id']}: expected null kwargs, '
            'got: ${pending.kwargs}',
      );
    } else {
      final expectedMap = Map<String, Object?>.from(
        expectedKwargs as Map<String, dynamic>,
      );
      expect(
        pending.kwargs,
        expectedMap,
        reason: 'Fixture #${fixture['id']}: expected kwargs '
            '$expectedMap, got: ${pending.kwargs}',
      );
    }
  }

  if (fixture['expectedCallIdNonZero'] == true) {
    expect(
      pending.callId,
      isNot(0),
      reason: 'Fixture #${fixture['id']}: expected nonzero callId, '
          'got: ${pending.callId}',
    );
  }

  final expectedMethodCall = fixture['expectedMethodCall'] as bool?;
  if (expectedMethodCall != null) {
    expect(
      pending.methodCall,
      expectedMethodCall,
      reason: 'Fixture #${fixture['id']}: expected methodCall '
          '$expectedMethodCall, got: ${pending.methodCall}',
    );
  }
}

/// Asserts M7A exception fields on a [MontyException] against fixture
/// expectations.
///
/// Checks these fixture keys (all optional — missing keys are no-ops):
/// - `expectedExcType` — expected `excType` string
/// - `expectedTracebackMinFrames` — minimum traceback frame count
/// - `expectedTracebackFrameHasFilename` — first frame has non-empty filename
/// - `expectedErrorFilename` — expected `filename` on the exception
/// - `expectedTracebackFilename` — some frame has this filename
void assertExceptionFields(
  MontyException exception,
  Map<String, dynamic> fixture,
) {
  final expectedExcType = fixture['expectedExcType'] as String?;
  if (expectedExcType != null) {
    expect(
      exception.excType,
      expectedExcType,
      reason: 'Fixture #${fixture['id']}: expected excType '
          '"$expectedExcType", got: "${exception.excType}"',
    );
  }

  final expectedMinFrames = fixture['expectedTracebackMinFrames'] as int?;
  if (expectedMinFrames != null) {
    final traceback = exception.traceback;
    expect(
      traceback.length,
      greaterThanOrEqualTo(expectedMinFrames),
      reason: 'Fixture #${fixture['id']}: expected >= $expectedMinFrames '
          'traceback frames, got: ${traceback.length}',
    );
  }

  if (fixture['expectedTracebackFrameHasFilename'] == true &&
      exception.traceback.isNotEmpty) {
    expect(
      exception.traceback.first.filename,
      isNotEmpty,
      reason: 'Fixture #${fixture['id']}: expected traceback frame '
          'to have non-empty filename',
    );
  }

  final expectedErrorFilename = fixture['expectedErrorFilename'] as String?;
  if (expectedErrorFilename != null) {
    expect(
      exception.filename,
      expectedErrorFilename,
      reason: 'Fixture #${fixture['id']}: expected error filename '
          '"$expectedErrorFilename", got: "${exception.filename}"',
    );
  }

  final expectedTracebackFilename =
      fixture['expectedTracebackFilename'] as String?;
  final tracebackFrames = exception.traceback;
  if (expectedTracebackFilename != null && tracebackFrames.isNotEmpty) {
    final hasFilename = tracebackFrames.any(
      (f) => f.filename == expectedTracebackFilename,
    );
    expect(
      hasFilename,
      isTrue,
      reason: 'Fixture #${fixture['id']}: expected traceback to contain '
          'frame with filename "$expectedTracebackFilename"',
    );
  }
}
