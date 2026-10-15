import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeEvent subclasses', () {
    test('BridgeRunStarted stores threadId and runId', () {
      const event = BridgeRunStarted(threadId: 't1', runId: 'r1');
      expect(event.threadId, 't1');
      expect(event.runId, 'r1');
      expect(event, isA<BridgeEvent>());
    });

    test('BridgeRunFinished stores all fields', () {
      const event = BridgeRunFinished(
        threadId: 't1',
        runId: 'r1',
        value: 42,
        printOutput: 'hello',
      );
      expect(event.threadId, 't1');
      expect(event.runId, 'r1');
      expect(event.value, 42);
      expect(event.printOutput, 'hello');
    });

    test('BridgeRunFinished allows null value and printOutput', () {
      const event = BridgeRunFinished(threadId: 't1', runId: 'r1');
      expect(event.value, isNull);
      expect(event.printOutput, isNull);
    });

    test('BridgeRunError stores message and optional fields', () async {
      final session = FakeMontySession()
        ..willRaise('ValueError', message: 'err');
      late final MontyError exception;
      try {
        await session.feedRun('raise ValueError("err")');
        fail('the scripted feed must raise');
      } on MontyError catch (e) {
        exception = e;
      }
      final event = BridgeRunError(
        message: 'fail',
        printOutput: 'output',
        exception: exception,
      );
      expect(event.message, 'fail');
      expect(event.printOutput, 'output');
      expect(event.exception, exception);
    });

    test('BridgeRunError allows null optional fields', () {
      const event = BridgeRunError(message: 'fail');
      expect(event.printOutput, isNull);
      expect(event.exception, isNull);
    });

    test('BridgeCallStarted stores callId', () {
      const event = BridgeCallStarted(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeCallFinished stores callId', () {
      const event = BridgeCallFinished(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeFunctionCallStart stores callId and name', () {
      const event = BridgeFunctionCallStart(callId: 'c1', name: 'fetch');
      expect(event.callId, 'c1');
      expect(event.name, 'fetch');
    });

    test('BridgeFunctionCallArgs stores callId and delta', () {
      const event = BridgeFunctionCallArgs(callId: 'c1', delta: '{"x":1}');
      expect(event.callId, 'c1');
      expect(event.delta, '{"x":1}');
    });

    test('BridgeFunctionCallEnd stores callId', () {
      const event = BridgeFunctionCallEnd(callId: 'c1');
      expect(event.callId, 'c1');
    });

    test('BridgeFunctionCallResult stores callId and result', () {
      const event = BridgeFunctionCallResult(callId: 'c1', result: 'ok');
      expect(event.callId, 'c1');
      expect(event.result, 'ok');
    });

    test('BridgeOsCallStart stores callId and operationName', () {
      const event = BridgeOsCallStart(
        callId: 'oc1',
        operationName: 'Path.read_text',
      );
      expect(event.callId, 'oc1');
      expect(event.operationName, 'Path.read_text');
    });

    test('BridgeOsCallResult stores callId and result', () {
      const event = BridgeOsCallResult(callId: 'oc1', result: 'contents');
      expect(event.callId, 'oc1');
      expect(event.result, 'contents');
    });

    test('BridgeChildEvent wraps inner event with childHandle', () {
      const inner = BridgeRunFinished(threadId: 't1', runId: 'r1', value: 42);
      const event = BridgeChildEvent(childHandle: '3', inner: inner);
      expect(event.childHandle, '3');
      expect(event.inner, inner);
      expect(event, isA<BridgeEvent>());
    });
  });

  group('BridgeEvent contract', () {
    /// One instance of each of the 13 subclasses, built with only the
    /// required parameters.
    const all = <BridgeEvent>[
      BridgeRunStarted(threadId: 't', runId: 'r'),
      BridgeRunFinished(threadId: 't', runId: 'r'),
      BridgeRunError(message: 'm'),
      BridgeCallStarted(callId: 'c'),
      BridgeCallFinished(callId: 'c'),
      BridgeFunctionCallStart(callId: 'c', name: 'n'),
      BridgeFunctionCallArgs(callId: 'c', delta: 'd'),
      BridgeFunctionCallEnd(callId: 'c'),
      BridgeFunctionCallResult(callId: 'c', result: 'r'),
      BridgeFunctionEmit(callId: 'c', text: 't'),
      BridgeOsCallStart(callId: 'c', operationName: 'o'),
      BridgeOsCallResult(callId: 'c', result: 'r'),
      BridgeChildEvent(
        childHandle: 'h',
        inner: BridgeRunStarted(threadId: 't', runId: 'r'),
      ),
    ];

    /// An exhaustive switch with no default: adding a subclass, or
    /// unsealing the base, breaks this at compile time.
    String kind(BridgeEvent e) => switch (e) {
      BridgeRunStarted() => 'runStarted',
      BridgeRunFinished() => 'runFinished',
      BridgeRunError() => 'runError',
      BridgeCallStarted() => 'callStarted',
      BridgeCallFinished() => 'callFinished',
      BridgeFunctionCallStart() => 'fnStart',
      BridgeFunctionCallArgs() => 'fnArgs',
      BridgeFunctionCallEnd() => 'fnEnd',
      BridgeFunctionCallResult() => 'fnResult',
      BridgeFunctionEmit() => 'fnEmit',
      BridgeOsCallStart() => 'osStart',
      BridgeOsCallResult() => 'osResult',
      BridgeChildEvent() => 'child',
    };

    test('a switch over the 13 subclasses is exhaustive', () {
      expect(all.map(kind).toSet(), hasLength(13));
    });

    test('the optional fields default to null', () {
      const finished = BridgeRunFinished(threadId: 't', runId: 'r');
      expect(finished.value, isNull);
      expect(finished.montyValue, isNull);
      expect(finished.printOutput, isNull);
      const error = BridgeRunError(message: 'm');
      expect(error.printOutput, isNull);
      expect(error.exception, isNull);
      const os = BridgeOsCallStart(callId: 'c', operationName: 'o');
      expect(os.argumentSummary, isNull);
      const result = BridgeOsCallResult(callId: 'c', result: 'r');
      expect(result.durationMs, isNull);
    });

    test('construction does no validation', () {
      expect(
        () => [
          BridgeRunStarted(threadId: ''.trim(), runId: ''.trim()),
          BridgeRunError(message: ''.trim()),
          BridgeOsCallResult(callId: ''.trim(), result: '', durationMs: -1),
          BridgeChildEvent(
            childHandle: ''.trim(),
            inner: BridgeRunError(message: ''.trim()),
          ),
        ],
        returnsNormally,
      );
    });
  });
}
