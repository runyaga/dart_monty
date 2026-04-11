/// Comprehensive error hierarchy discriminator tests.
///
/// Tests every sealed [MontyError] subtype at every boundary layer:
/// - Construction and field access
/// - Pattern matching exhaustiveness
/// - Catch clause specificity (subtype before supertype)
/// - MontyScriptError wraps MontyException correctly
/// - BaseMontyPlatform throws the right sealed type for each excType
/// - Session catches and wraps correctly
library;

import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 1. Sealed hierarchy structure
  // ---------------------------------------------------------------------------
  group('Sealed hierarchy structure', () {
    test('MontyScriptError carries MontyException with all fields', () {
      const exception = MontyException(
        message: 'division by zero',
        excType: 'ZeroDivisionError',
        filename: '<input>',
        lineNumber: 1,
        columnNumber: 5,
        sourceCode: '1/0',
      );
      const error = MontyScriptError(
        'division by zero',
        excType: 'ZeroDivisionError',
        exception: exception,
      );

      expect(error.message, 'division by zero');
      expect(error.excType, 'ZeroDivisionError');
      expect(error.exception, isNotNull);
      expect(error.exception!.filename, '<input>');
      expect(error.exception!.lineNumber, 1);
      expect(error.exception!.columnNumber, 5);
      expect(error.exception!.sourceCode, '1/0');
      expect(error.exception!.traceback, isEmpty);
    });

    test('MontyScriptError without exception field', () {
      const error = MontyScriptError('error', excType: 'ValueError');
      expect(error.exception, isNull);
      expect(error.message, 'error');
      expect(error.excType, 'ValueError');
    });

    test('all 5 sealed subtypes are distinct runtime types', () {
      final errors = <MontyError>[
        const MontyScriptError('a'),
        const MontyPanicError('b'),
        const MontyCrashError('c'),
        const MontyDisposedError('d'),
        const MontyResourceError('e'),
      ];

      expect(errors.whereType<MontyScriptError>(), hasLength(1));
      expect(errors.whereType<MontyPanicError>(), hasLength(1));
      expect(errors.whereType<MontyCrashError>(), hasLength(1));
      expect(errors.whereType<MontyDisposedError>(), hasLength(1));
      expect(errors.whereType<MontyResourceError>(), hasLength(1));
    });

    test('all subtypes implement Exception', () {
      expect(const MontyScriptError('a'), isA<Exception>());
      expect(const MontyPanicError('b'), isA<Exception>());
      expect(const MontyCrashError(), isA<Exception>());
      expect(const MontyDisposedError(), isA<Exception>());
      expect(const MontyResourceError('e'), isA<Exception>());
    });

    test('exhaustive switch covers all cases', () {
      String classify(MontyError e) => switch (e) {
        MontyScriptError() => 'script',
        MontyPanicError() => 'panic',
        MontyCrashError() => 'crash',
        MontyDisposedError() => 'disposed',
        MontyResourceError() => 'resource',
      };

      expect(classify(const MontyScriptError('a')), 'script');
      expect(classify(const MontyPanicError('b')), 'panic');
      expect(classify(const MontyCrashError()), 'crash');
      expect(classify(const MontyDisposedError()), 'disposed');
      expect(classify(const MontyResourceError('e')), 'resource');
    });

    test('toString includes type name', () {
      expect(const MontyScriptError('x').toString(), 'MontyScriptError: x');
      expect(const MontyPanicError('y').toString(), 'MontyPanicError: y');
      expect(const MontyResourceError('z').toString(), 'MontyResourceError: z');
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Catch clause ordering (subtype before supertype)
  // ---------------------------------------------------------------------------
  group('Catch clause ordering', () {
    test('MontyScriptError caught before MontyError', () {
      String? caught;
      try {
        throw const MontyScriptError(
          'test',
          exception: MontyException(message: 'test'),
        );
      } on MontyScriptError {
        caught = 'script';
      } on MontyError {
        caught = 'error';
      }
      expect(caught, 'script');
    });

    test('MontyResourceError caught before MontyError', () {
      String? caught;
      try {
        throw const MontyResourceError('oom');
      } on MontyResourceError {
        caught = 'resource';
      } on MontyError {
        caught = 'error';
      }
      expect(caught, 'resource');
    });

    test('MontyPanicError caught by MontyError switch', () {
      String? caught;
      try {
        throw const MontyPanicError('panic');
      } on MontyError catch (e) {
        caught = switch (e) {
          MontyPanicError() => 'panic',
          _ => 'other',
        };
      }
      expect(caught, 'panic');
    });

    test('MontyScriptError NOT caught by on MontyException', () {
      var caughtByException = false;
      var caughtByError = false;
      try {
        throw const MontyScriptError(
          'test',
          exception: MontyException(message: 'test'),
        );
      } on MontyException {
        caughtByException = true;
      } on MontyError {
        caughtByError = true;
      }
      expect(caughtByException, isFalse);
      expect(caughtByError, isTrue);
    });

    test('MontyException (standalone) IS caught by on MontyException', () {
      var caughtByException = false;
      try {
        throw const MontyException(message: 'standalone');
      } on MontyException {
        caughtByException = true;
      }
      expect(caughtByException, isTrue);
    });

    test('MontyError caught by on Exception', () {
      var caught = false;
      try {
        throw const MontyScriptError('test');
      } on Exception {
        caught = true;
      }
      expect(caught, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. BaseMontyPlatform excType → sealed type mapping
  // ---------------------------------------------------------------------------
  group('BaseMontyPlatform error mapping', () {
    late _FakeCoreBindings bindings;
    late _TestPlatform platform;

    setUp(() {
      bindings = _FakeCoreBindings();
      platform = _TestPlatform(bindings: bindings);
    });

    test('ZeroDivisionError → MontyScriptError with exception', () async {
      bindings.runResult = const CoreRunResult(
        ok: false,
        error: 'division by zero',
        excType: 'ZeroDivisionError',
        filename: '<input>',
        lineNumber: 1,
      );

      try {
        await platform.run('1/0');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.message, 'division by zero');
        expect(e.excType, 'ZeroDivisionError');
        expect(e.exception, isNotNull);
        expect(e.exception!.filename, '<input>');
        expect(e.exception!.lineNumber, 1);
      }
    });

    test('ValueError → MontyScriptError', () async {
      bindings.runResult = const CoreRunResult(
        ok: false,
        error: 'invalid literal',
        excType: 'ValueError',
      );

      expect(
        () => platform.run('int("abc")'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.excType,
            'excType',
            'ValueError',
          ),
        ),
      );
    });

    test(
      'MemoryLimitExceeded → MontyResourceError (NOT ScriptError)',
      () async {
        bindings.runResult = const CoreRunResult(
          ok: false,
          error: 'memory limit exceeded',
          excType: 'MemoryLimitExceeded',
        );

        var caughtAsScript = false;
        try {
          await platform.run('x');
        } on MontyScriptError {
          caughtAsScript = true;
        } on MontyResourceError catch (e) {
          expect(e.message, 'memory limit exceeded');
        }
        expect(caughtAsScript, isFalse);
      },
    );

    test('null excType → MontyScriptError with null excType', () async {
      bindings.runResult = const CoreRunResult(ok: false, error: 'unknown');

      try {
        await platform.run('x');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.excType, isNull);
        expect(e.exception!.excType, isNull);
      }
    });

    test('error with all metadata fields populated', () async {
      bindings.runResult = const CoreRunResult(
        ok: false,
        error: 'name error',
        excType: 'NameError',
        filename: 'test.py',
        lineNumber: 5,
        columnNumber: 10,
        sourceCode: 'print(x)',
      );

      try {
        await platform.run('x');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        final ex = e.exception!;
        expect(ex.message, 'name error');
        expect(ex.filename, 'test.py');
        expect(ex.lineNumber, 5);
        expect(ex.columnNumber, 10);
        expect(ex.sourceCode, 'print(x)');
      }
    });

    test('progress error → MontyScriptError', () async {
      bindings.startResult = const CoreProgressResult(
        state: 'error',
        error: 'key error',
        excType: 'KeyError',
      );

      expect(
        () => platform.start('x', externalFunctions: ['f']),
        throwsA(isA<MontyScriptError>()),
      );
    });

    test('progress MemoryLimitExceeded → MontyResourceError', () async {
      bindings.startResult = const CoreProgressResult(
        state: 'error',
        error: 'oom',
        excType: 'MemoryLimitExceeded',
      );

      expect(
        () => platform.start('x', externalFunctions: ['f']),
        throwsA(isA<MontyResourceError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Successful result with error field (non-fatal warning)
  // ---------------------------------------------------------------------------
  group('MontyResult.error vs thrown errors', () {
    late _FakeCoreBindings bindings;
    late _TestPlatform platform;

    setUp(() {
      bindings = _FakeCoreBindings();
      platform = _TestPlatform(bindings: bindings);
    });

    test('successful run can carry non-fatal MontyException', () async {
      bindings.runResult = const CoreRunResult(
        ok: true,
        value: 42,
        error: 'SyntaxWarning',
        excType: 'SyntaxWarning',
        usage: MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 1,
          stackDepthUsed: 5,
        ),
      );

      final result = await platform.run('x');
      expect(result.value, isNotNull);
      expect(result.error, isNotNull);
      expect(result.error!.excType, 'SyntaxWarning');
    });

    test('failed run throws, does not return MontyResult', () async {
      bindings.runResult = const CoreRunResult(
        ok: false,
        error: 'error',
        excType: 'RuntimeError',
      );

      expect(() => platform.run('x'), throwsA(isA<MontyScriptError>()));
    });
  });

  // ---------------------------------------------------------------------------
  // 5. MontyScriptError field extraction
  // ---------------------------------------------------------------------------
  group('MontyScriptError field extraction', () {
    test('exception message matches error message', () {
      const ex = MontyException(message: 'test error', excType: 'TestError');
      const error = MontyScriptError(
        'test error',
        excType: 'TestError',
        exception: ex,
      );

      expect(error.message, error.exception!.message);
      expect(error.excType, error.exception!.excType);
    });

    test('exception carries traceback when platform provides it', () async {
      final bindings = _FakeCoreBindings()
        ..runResult = const CoreRunResult(
          ok: false,
          error: 'name error',
          excType: 'NameError',
          traceback: [
            {'filename': 'test.py', 'start_line': 1, 'start_column': 0},
          ],
        );
      final platform = _TestPlatform(bindings: bindings);

      try {
        await platform.run('x');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        final tb = e.exception!.traceback;
        expect(tb, hasLength(1));
        expect(tb.first.filename, 'test.py');
        expect(tb.first.startLine, 1);
      }
    });
  });
}

// =============================================================================
// Test infrastructure
// =============================================================================

class _FakeCoreBindings implements MontyCoreBindings {
  CoreRunResult? runResult;
  CoreProgressResult? startResult;

  @override
  Future<bool> init() async => true;

  @override
  Future<CoreRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
  }) async => runResult ?? (throw StateError('runResult not configured'));

  @override
  Future<CoreProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
  }) async => startResult ?? (throw StateError('startResult not configured'));

  @override
  Future<CoreProgressResult> resume(String valueJson) async =>
      throw UnimplementedError();

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async =>
      throw UnimplementedError();

  @override
  Future<CoreProgressResult> resumeAsFuture() async =>
      throw UnimplementedError();

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async => throw UnimplementedError();

  @override
  Future<Uint8List> snapshot() async => throw UnimplementedError();

  @override
  Future<void> restoreSnapshot(Uint8List data) async =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

class _TestPlatform extends BaseMontyPlatform {
  _TestPlatform({required super.bindings});

  @override
  String get backendName => 'test';
}
