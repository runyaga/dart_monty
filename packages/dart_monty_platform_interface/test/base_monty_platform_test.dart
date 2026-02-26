import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

class _FakeCoreBindings implements MontyCoreBindings {
  CoreRunResult? runResult;
  CoreProgressResult? progressResult;
  int initCallCount = 0;
  bool disposeCalled = false;
  String? lastRunCode;
  String? lastLimitsJson;
  String? lastExtFnsJson;
  String? lastScriptName;
  String? lastValueJson;
  String? lastErrorMessage;

  @override
  Future<bool> init() async {
    initCallCount++;
    return true;
  }

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async {
    lastRunCode = code;
    lastLimitsJson = limitsJson;
    lastScriptName = scriptName;
    return runResult!;
  }

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async {
    lastRunCode = code;
    lastExtFnsJson = extFnsJson;
    lastLimitsJson = limitsJson;
    lastScriptName = scriptName;
    return progressResult!;
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    lastValueJson = valueJson;
    return progressResult!;
  }

  @override
  Future<CoreProgressResult> resumeWithError(
    String errorMessage,
  ) async {
    lastErrorMessage = errorMessage;
    return progressResult!;
  }

  @override
  Future<CoreProgressResult> resumeAsFuture() async =>
      throw UnimplementedError();

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async =>
      throw UnimplementedError();

  @override
  Future<Uint8List> snapshot() async => throw UnimplementedError();

  @override
  Future<void> restoreSnapshot(Uint8List data) async =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {
    disposeCalled = true;
  }
}

class _TestPlatform extends BaseMontyPlatform {
  _TestPlatform({required super.bindings});

  @override
  String get backendName => 'Test';

  /// Expose protected state transitions for testing.
  void forceActive() => markActive();
}

void main() {
  late _FakeCoreBindings fake;
  late _TestPlatform platform;

  setUp(() {
    fake = _FakeCoreBindings();
    platform = _TestPlatform(bindings: fake);
  });

  const usage = MontyResourceUsage(
    memoryBytesUsed: 100,
    timeElapsedMs: 5,
    stackDepthUsed: 3,
  );

  const zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  group('run()', () {
    test('success returns MontyResult with value and usage', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        value: 42,
        usage: usage,
      );

      final result = await platform.run('1 + 1');

      expect(result.value, 42);
      expect(result.usage, usage);
      expect(result.printOutput, isNull);
      expect(result.isError, isFalse);
      expect(fake.lastRunCode, '1 + 1');
    });

    test('error throws MontyException', () async {
      fake.runResult = const CoreRunResult(
        ok: false,
        error: 'division by zero',
        excType: 'ZeroDivisionError',
        traceback: [
          {
            'filename': '<test>',
            'start_line': 1,
            'start_column': 0,
          },
        ],
      );

      expect(
        () => platform.run('1 / 0'),
        throwsA(
          isA<MontyException>()
              .having((e) => e.message, 'message', 'division by zero')
              .having(
                (e) => e.excType,
                'excType',
                'ZeroDivisionError',
              )
              .having(
                (e) => e.traceback,
                'traceback',
                hasLength(1),
              ),
        ),
      );
    });

    test('null usage falls back to zero usage', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        value: 'hello',
      );

      final result = await platform.run('code');

      expect(result.usage, zeroUsage);
    });

    test('printOutput is preserved', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
        printOutput: 'hello world\n',
      );

      final result = await platform.run('print("hello world")');

      expect(result.printOutput, 'hello world\n');
    });

    test('passes scriptName to bindings', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run('code', scriptName: 'math.py');

      expect(fake.lastScriptName, 'math.py');
    });

    test('ok with embedded error preserves error in result', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
        error: 'NameError',
        excType: 'NameError',
      );

      final result = await platform.run('code');

      expect(result.isError, isTrue);
      expect(result.error?.message, 'NameError');
      expect(result.error?.excType, 'NameError');
      expect(result.value, isNull);
    });
  });

  group('start()', () {
    test('complete with embedded error preserves error', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        usage: usage,
        error: 'caught',
        excType: 'RuntimeError',
      );

      final progress = await platform.start('code');

      final complete = progress as MontyComplete;
      expect(complete.result.isError, isTrue);
      expect(complete.result.error?.message, 'caught');
      expect(complete.result.error?.excType, 'RuntimeError');
    });

    test('complete returns MontyComplete and marks idle', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        value: 99,
        usage: usage,
      );

      final progress = await platform.start('code');

      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.value, 99);
      expect(complete.result.usage, usage);
      expect(platform.isIdle, isTrue);
    });

    test('pending returns MontyPending and marks active', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'pending',
        functionName: 'get_data',
        arguments: [1, 'two'],
        callId: 7,
        methodCall: true,
      );

      final progress = await platform.start(
        'code',
        externalFunctions: ['get_data'],
      );

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'get_data');
      expect(pending.arguments, [1, 'two']);
      expect(pending.kwargs, isNull);
      expect(pending.callId, 7);
      expect(pending.methodCall, isTrue);
      expect(platform.isActive, isTrue);
    });

    test('pending with kwargs preserves kwargs map', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'pending',
        functionName: 'fetch',
        arguments: ['url'],
        kwargs: {'timeout': 30, 'retry': true},
        callId: 1,
      );

      final progress = await platform.start(
        'code',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.kwargs, {'timeout': 30, 'retry': true});
    });

    test(
      'resolve_futures returns MontyResolveFutures '
      'and marks active',
      () async {
        fake.progressResult = const CoreProgressResult(
          state: 'resolve_futures',
          pendingCallIds: [1, 2, 3],
        );

        final progress = await platform.start(
          'code',
          externalFunctions: ['fn'],
        );

        expect(progress, isA<MontyResolveFutures>());
        final rf = progress as MontyResolveFutures;
        expect(rf.pendingCallIds, [1, 2, 3]);
        expect(platform.isActive, isTrue);
      },
    );

    test('error throws MontyException and marks idle', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'error',
        error: 'name not defined',
        excType: 'NameError',
      );

      await expectLater(
        () => platform.start('code'),
        throwsA(
          isA<MontyException>()
              .having(
                (e) => e.message,
                'message',
                'name not defined',
              )
              .having(
                (e) => e.excType,
                'excType',
                'NameError',
              ),
        ),
      );
      expect(platform.isIdle, isTrue);
    });
  });

  group('resume()', () {
    test('delegates valueJson and translates progress', () async {
      // Enter active state via start().
      fake.progressResult = const CoreProgressResult(
        state: 'pending',
        functionName: 'fn',
      );
      await platform.start(
        'code',
        externalFunctions: ['fn'],
      );

      // Now resume.
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        value: 'done',
        usage: usage,
      );
      final progress = await platform.resume(42);

      expect(fake.lastValueJson, json.encode(42));
      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.value, 'done');
    });
  });

  group('resumeWithError()', () {
    test(
      'delegates errorMessage and translates progress',
      () async {
        // Enter active state.
        fake.progressResult = const CoreProgressResult(
          state: 'pending',
          functionName: 'fn',
        );
        await platform.start(
          'code',
          externalFunctions: ['fn'],
        );

        // Resume with error -> complete.
        fake.progressResult = const CoreProgressResult(
          state: 'complete',
          usage: usage,
        );
        final progress = await platform.resumeWithError(
          'not found',
        );

        expect(fake.lastErrorMessage, 'not found');
        expect(progress, isA<MontyComplete>());
      },
    );
  });

  group('dispose()', () {
    test('delegates to bindings and marks disposed', () async {
      await platform.dispose();

      expect(fake.disposeCalled, isTrue);
      expect(platform.isDisposed, isTrue);
    });

    test('second call is a no-op', () async {
      await platform.dispose();
      fake.disposeCalled = false;

      await platform.dispose();

      expect(fake.disposeCalled, isFalse);
    });
  });

  group('state guards', () {
    test('run() while active throws StateError', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'pending',
        functionName: 'fn',
      );
      await platform.start(
        'code',
        externalFunctions: ['fn'],
      );

      expect(
        () => platform.run('code'),
        throwsA(isA<StateError>()),
      );
    });

    test('resume() while idle throws StateError', () {
      expect(
        () => platform.resume(null),
        throwsA(isA<StateError>()),
      );
    });

    test('resumeWithError() while idle throws StateError', () {
      expect(
        () => platform.resumeWithError('err'),
        throwsA(isA<StateError>()),
      );
    });

    test('run() after disposed throws StateError', () async {
      await platform.dispose();

      expect(
        () => platform.run('code'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'start() after disposed throws StateError',
      () async {
        await platform.dispose();

        expect(
          () => platform.start('code'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'resume() after disposed throws StateError',
      () async {
        await platform.dispose();
        // Also not active, but disposed check comes first.
        expect(
          () => platform.resume(null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('disposed'),
            ),
          ),
        );
      },
    );

    test(
      'run() rejects non-empty inputs',
      () async {
        expect(
          () => platform.run('code', inputs: {'x': 1}),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );
  });

  group('limits encoding', () {
    test('null limits passes null to bindings', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run('code');

      expect(fake.lastLimitsJson, isNull);
    });

    test('partial limits encodes JSON subset', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run(
        'code',
        limits: const MontyLimits(memoryBytes: 1024),
      );

      final decoded = json.decode(fake.lastLimitsJson!) as Map<String, dynamic>;
      expect(decoded, {'memory_bytes': 1024});
    });

    test('full limits encodes all fields', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run(
        'code',
        limits: const MontyLimits(
          memoryBytes: 1024,
          timeoutMs: 5000,
          stackDepth: 100,
        ),
      );

      final decoded = json.decode(fake.lastLimitsJson!) as Map<String, dynamic>;
      expect(decoded, {
        'memory_bytes': 1024,
        'timeout_ms': 5000,
        'stack_depth': 100,
      });
    });
  });

  group('external functions encoding', () {
    test('null passes null to bindings', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        usage: usage,
      );

      await platform.start('code');

      expect(fake.lastExtFnsJson, isNull);
    });

    test('empty list passes null to bindings', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        usage: usage,
      );

      await platform.start('code', externalFunctions: []);

      expect(fake.lastExtFnsJson, isNull);
    });

    test('non-empty list encodes JSON array', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'complete',
        usage: usage,
      );

      await platform.start(
        'code',
        externalFunctions: ['fn_a', 'fn_b'],
      );

      final decoded = json.decode(fake.lastExtFnsJson!) as List<dynamic>;
      expect(decoded, ['fn_a', 'fn_b']);
    });
  });

  group('lazy initialization', () {
    test('first call triggers init', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run('code');

      expect(fake.initCallCount, 1);
    });

    test('subsequent calls skip init', () async {
      fake.runResult = const CoreRunResult(
        ok: true,
        usage: usage,
      );

      await platform.run('first');
      await platform.run('second');

      expect(fake.initCallCount, 1);
    });
  });

  group('unknown progress state', () {
    test('throws StateError', () async {
      fake.progressResult = const CoreProgressResult(
        state: 'bogus',
      );

      await expectLater(
        () => platform.start('code'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('bogus'),
          ),
        ),
      );
      expect(platform.isIdle, isTrue);
    });
  });
}
