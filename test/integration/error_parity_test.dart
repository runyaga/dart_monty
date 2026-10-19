@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '../fixtures/error_parity.dart';

void main() {
  final cases = loadErrorParityCases();

  for (final testCase in cases) {
    final skipReason = _skipReason(testCase);
    final hasBadFormat = testCase.expected.any(
      (step) => step.display?.badFormat != null,
    );
    final testName = hasBadFormat
        ? '${testCase.id} (DIV: display bad format throws ArgumentError '
              'instead of ValueError)'
        : testCase.id;

    test(
      testName,
      skip: skipReason,
      () async {
        final runtime = await MontyRuntime.start(
          logger: BridgeLogger.silent,
          limits: _buildLimits(testCase.limits),
        );
        addTearDown(runtime.dispose);

        final recordedExtCalls = <Map<String, Object?>>[];
        _registerExternals(runtime, testCase.externals, recordedExtCalls);

        final feeds = testCase.feeds ?? <String>[testCase.code!];
        expect(
          feeds,
          hasLength(testCase.expected.length),
          reason: 'Feed count must match expected step count',
        );

        for (var i = 0; i < feeds.length; i++) {
          final feed = feeds.elementAtOrNull(i)!;
          final step = testCase.expected.elementAtOrNull(i)!;
          final inputs = i == 0 ? _decodeInputs(testCase.inputs) : null;
          recordedExtCalls.clear();

          final handle = runtime.execute(feed, inputs: inputs);
          final eventsFuture = handle.events.toList();

          MontyValue? actualValue;
          MontyError? actualError;
          try {
            actualValue = await handle.result;
          } on MontyError catch (e) {
            actualError = e;
          }

          final events = await eventsFuture;
          _verifyStep(
            step: step,
            normalizeNumbers: testCase.normalizeNumbers,
            events: events,
            actualExtCalls: List<Map<String, Object?>>.of(recordedExtCalls),
            actualValue: actualValue,
            actualError: actualError,
          );
        }
      },
    );
  }
}

String? _skipReason(ErrorParityCase testCase) {
  final autoExternals = testCase.autoExternals;
  if (autoExternals != null && autoExternals.isNotEmpty) {
    return 'MontyRuntime does not support auto_externals without registration';
  }
  final limits = testCase.limits;
  if (limits != null) {
    const supportedLimits = {
      'max_recursion_depth',
      'max_memory',
      'gc_interval',
      'max_suspensions',
      'max_feed_duration_secs',
      'max_turn_duration_secs',
      'max_total_sleep_secs',
    };
    final unsupported = limits.keys.where(
      (k) => !supportedLimits.contains(k),
    );
    if (unsupported.isNotEmpty) {
      return 'Unsupported resource limits: ${unsupported.join(', ')}';
    }
  }

  return null;
}

ResourceLimits? _buildLimits(Map<String, Object?>? raw) {
  if (raw == null) return null;

  return ResourceLimits(
    maxRecursionDepth: raw['max_recursion_depth'] as int?,
    maxMemory: raw['max_memory'] as int?,
    gcInterval: raw['gc_interval'] as int?,
    maxSuspensions: raw['max_suspensions'] as int?,
    maxFeedDuration: _durationSecs(raw['max_feed_duration_secs']),
    maxTurnDuration: _durationSecs(raw['max_turn_duration_secs']),
    maxTotalSleep: _durationSecs(raw['max_total_sleep_secs']),
  );
}

Duration? _durationSecs(Object? raw) {
  if (raw case final num seconds) {
    return Duration(microseconds: (seconds * 1000000).round());
  }

  return null;
}

Map<String, Object?>? _decodeInputs(Map<String, Object?>? raw) {
  if (raw == null) return null;

  return {
    for (final MapEntry(:key, :value) in raw.entries)
      key: _decodeTaggedValue(value),
  };
}

void _registerExternals(
  MontyRuntime runtime,
  Map<String, Object?>? externals,
  List<Map<String, Object?>> recordedExtCalls,
) {
  if (externals == null) return;

  for (final MapEntry(key: name, value: rawScript) in externals.entries) {
    final script = [
      if (rawScript case final List<Object?> items)
        for (final item in items)
          if (item case final Map<String, Object?> stepMap) stepMap,
    ];
    var callIndex = 0;

    runtime.register(
      HostFunction(
        schema: HostFunctionSchema(name: name),
        handler: (args, ctx) {
          recordedExtCalls.add({
            'name': name,
            'args': const <MontyValue>[],
            'kwargs': <String, MontyValue>{
              for (final MapEntry(:key, :value) in args.entries) key: value,
            },
          });
          final step = script.elementAtOrNull(callIndex++);
          if (step == null) {
            throw StateError(
              'External "$name" called more than ${script.length} time(s)',
            );
          }
          if (step.containsKey('return')) {
            return Future.value(_decodeTaggedValue(step['return']));
          }
          if (step['raise'] case final Map<String, Object?> raiseSpec) {
            final type = raiseSpec['type']! as String;
            final message = raiseSpec['message'] as String?;
            throw ExternalException(type, message);
          }
          throw StateError('Invalid external script step for "$name": $step');
        },
      ),
    );
  }
}

MontyValue _decodeTaggedValue(Object? raw) {
  if (raw == null) return const MontyNone();
  if (raw case final Map<String, Object?> map) {
    final tag = map['t'];
    if (tag is String) {
      return switch (tag) {
        'none' => const MontyNone(),
        'bool' => MontyBool(map['v']! as bool),
        'int' => switch (map['v']) {
          final int n => MontyInt(n),
          final String s => MontyInt(int.parse(s)),
          final other => throw FormatException('Invalid int tag value: $other'),
        },
        'float' => MontyFloat((map['v']! as num).toDouble()),
        'str' => MontyString(map['v']! as String),
        'bytes' => MontyBytes(_decodeHex(map['hex']! as String)),
        'list' => MontyList([
          for (final item in map['items']! as List<Object?>)
            _decodeTaggedValue(item),
        ]),
        'tuple' => MontyTuple([
          for (final item in map['items']! as List<Object?>)
            _decodeTaggedValue(item),
        ]),
        'dict' => MontyDict([
          for (final pair in map['items']! as List<Object?>)
            if (pair case final List<Object?> pairItems)
              (
                _decodeTaggedValue(pairItems.firstOrNull),
                _decodeTaggedValue(pairItems.elementAtOrNull(1)),
              ),
        ]),
        _ => MontyValue.fromDart(raw),
      };
    }
  }

  return MontyValue.fromDart(raw);
}

Uint8List _decodeHex(String hex) {
  final byteLength = hex.length ~/ 2;
  final bytes = <int>[
    for (var i = 0; i < byteLength; i++)
      int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  ];

  return Uint8List.fromList(bytes);
}

Map<String, MontyValue> _decodeExpectedAttributes(Map<String, Object?> data) =>
    {
      for (final MapEntry(:key, :value) in data.entries)
        if (key != 'kind') key: _decodeTaggedValue(value),
    };

List<Map<String, Object?>> _decodeExpectedExtCalls(
  List<Map<String, Object?>> rawCalls,
) => [
  for (final call in rawCalls)
    {
      'name': call['name']! as String,
      'args': [
        if (call['args'] case final List<Object?> items)
          for (final item in items) _decodeTaggedValue(item),
      ],
      'kwargs': {
        if (call['kwargs'] case final Map<Object?, Object?> kwargsMap)
          for (final MapEntry(:key, :value) in kwargsMap.entries)
            if (key case final String k) k: _decodeTaggedValue(value),
      },
    },
];

void _verifyStep({
  required ErrorParityStep step,
  required bool normalizeNumbers,
  required List<BridgeEvent> events,
  required List<Map<String, Object?>> actualExtCalls,
  required MontyValue? actualValue,
  required MontyError? actualError,
}) {
  String norm(String text) =>
      normalizeNumbers ? text.replaceAll(RegExp(r'\d+'), 'N') : text;
  final expectedPrint = _concatPrints(step.prints);
  final expectedException = step.exception;

  expect(actualExtCalls, _decodeExpectedExtCalls(step.extCalls));

  if (expectedException != null) {
    expect(actualError, isNotNull, reason: 'Expected step to raise an error');
    final error = actualError!;

    final runErrors = events.whereType<BridgeRunError>().toList();
    expect(runErrors, hasLength(1));
    final runError = runErrors.firstOrNull!;
    expect(runError.printOutput ?? '', expectedPrint);

    switch (step.errorClass) {
      case 'MontyRuntimeError':
        expect(error, isA<MontyRuntimeError>());
      case 'MontySyntaxError':
        expect(error, isA<MontySyntaxError>());
      case 'MontyTypingError':
        expect(error, isA<MontyTypingError>());
      case 'MontyCrashedError':
        expect(error, isA<MontyCrashedError>());
      case final other:
        fail('Unexpected error_class in fixture: $other');
    }

    final innerException = error.exception;
    expect(innerException.excType, expectedException.type);
    expect(norm(innerException.message ?? ''), expectedException.message);

    final actualFrames = switch (error) {
      final MontyRuntimeError e => e.traceback,
      final MontySyntaxError e => e.traceback,
      _ => const <Frame>[],
    };

    final expectedFrames = expectedException.traceback;
    expect(actualFrames, hasLength(expectedFrames.length));
    for (var i = 0; i < expectedFrames.length; i++) {
      final expectedFrame = expectedFrames.elementAtOrNull(i)!;
      final actualFrame = actualFrames.elementAtOrNull(i)!;
      expect(
        actualFrame.filename,
        expectedFrame.filename,
        reason: 'frame $i filename',
      );
      expect(actualFrame.line, expectedFrame.line, reason: 'frame $i line');
      expect(
        actualFrame.column,
        expectedFrame.column,
        reason: 'frame $i column',
      );
      expect(
        actualFrame.endLine,
        expectedFrame.endLine,
        reason: 'frame $i endLine',
      );
      expect(
        actualFrame.endColumn,
        expectedFrame.endColumn,
        reason: 'frame $i endColumn',
      );
      expect(
        actualFrame.functionName,
        expectedFrame.function,
        reason: 'frame $i functionName',
      );
      expect(
        actualFrame.sourceLine,
        expectedFrame.sourceLine,
        reason: 'frame $i sourceLine',
      );
    }

    final expectedDisplay = step.display;
    expect(expectedDisplay, isNotNull);
    final display = expectedDisplay!;
    final expectedTracebackText = display.traceback;
    final expectedTypeMsg = display.typeMsg;
    final expectedMsg = display.msg;

    expect(norm(error.toString()), display.str);
    expect(norm(runError.displayMessage), expectedTracebackText);

    switch (error) {
      case final MontyRuntimeError e:
        expect(norm(e.display()), expectedTracebackText);
        expect(norm(e.display('type-msg')), expectedTypeMsg);
        expect(norm(e.display('msg')), expectedMsg);
        _verifyDisplayException(innerException, display.exception, norm);
        _verifyBadFormat(() => e.display('nope'), display.badFormat);
      case final MontySyntaxError e:
        expect(norm(e.display()), expectedTracebackText);
        expect(norm(e.display('type-msg')), expectedTypeMsg);
        expect(norm(e.display('msg')), expectedMsg);
        _verifyDisplayException(innerException, display.exception, norm);
        _verifyBadFormat(() => e.display('nope'), display.badFormat);
      case final MontyTypingError e:
        final rendered = norm(e.display());
        expect(rendered, expectedTracebackText);
        expect(rendered, expectedTypeMsg);
        expect(rendered, expectedMsg);
      case MontyCrashedError():
        break;
    }

    final expectedData = display.data ?? expectedException.data;
    if (expectedData != null) {
      expect(
        innerException.attributes,
        _decodeExpectedAttributes(expectedData),
      );
    } else {
      expect(innerException.attributes, isEmpty);
    }
  } else {
    expect(actualError, isNull, reason: 'Expected step to succeed');
    expect(actualValue, isNotNull);

    final finishedEvents = events.whereType<BridgeRunFinished>().toList();
    expect(finishedEvents, hasLength(1));
    expect(finishedEvents.firstOrNull!.printOutput ?? '', expectedPrint);

    final stepValue = step.value;
    if (stepValue != null) {
      expect(actualValue, _decodeTaggedValue(stepValue));
    }
  }
}

void _verifyDisplayException(
  MontyExceptionValue actual,
  Map<String, Object?> expected,
  String Function(String) norm,
) {
  final expectedType = expected['type']! as String;
  expect(actual.excType.split('.').lastOrNull, expectedType);

  final decodedArgs = _decodeTaggedValue(expected['args']);
  expect(decodedArgs, isA<MontyTuple>());
  if (decodedArgs case MontyTuple(:final items)) {
    final firstArg = items.firstOrNull;
    if (items.length == 1 && firstArg is MontyString) {
      expect(norm(actual.message ?? ''), firstArg.value);
    }
  }
}

void _verifyBadFormat(
  void Function() invokeBadFormat,
  Map<String, Object?>? badFormat,
) {
  if (badFormat == null) return;
  final expectedMessage = badFormat['message']! as String;
  expect(
    invokeBadFormat,
    throwsA(
      isA<ArgumentError>().having(
        (e) => e.message,
        'message',
        expectedMessage,
      ),
    ),
  );
}

String _concatPrints(List<Map<String, Object?>> prints) {
  final buffer = StringBuffer();
  for (final entry in prints) {
    if (entry['text'] case final String text) {
      buffer.write(text);
    }
  }

  return buffer.toString();
}
