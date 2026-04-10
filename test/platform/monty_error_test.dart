import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  group('MontyError sealed hierarchy', () {
    group('MontyScriptError', () {
      test('construction with message only', () {
        const error = MontyScriptError('name x is not defined');
        expect(error.message, 'name x is not defined');
        expect(error.excType, isNull);
      });

      test('construction with excType', () {
        const error = MontyScriptError(
          'division by zero',
          excType: 'ZeroDivisionError',
        );
        expect(error.message, 'division by zero');
        expect(error.excType, 'ZeroDivisionError');
      });

      test('toString', () {
        const error = MontyScriptError('bad value');
        expect(error.toString(), 'MontyScriptError: bad value');
      });

      test('implements Exception', () {
        const error = MontyScriptError('err');
        expect(error, isA<Exception>());
        expect(error, isA<MontyError>());
      });
    });

    group('MontyPanicError', () {
      test('construction', () {
        const error = MontyPanicError('rust panic: index out of bounds');
        expect(error.message, 'rust panic: index out of bounds');
      });

      test('toString', () {
        const error = MontyPanicError('panic');
        expect(error.toString(), 'MontyPanicError: panic');
      });
    });

    group('MontyCrashError', () {
      test('construction with default message', () {
        const error = MontyCrashError();
        expect(error.message, 'Interpreter crashed unexpectedly');
      });

      test('construction with custom message', () {
        const error = MontyCrashError('isolate died');
        expect(error.message, 'isolate died');
      });

      test('toString', () {
        const error = MontyCrashError();
        expect(
          error.toString(),
          'MontyCrashError: Interpreter crashed unexpectedly',
        );
      });
    });

    group('MontyDisposedError', () {
      test('construction with default message', () {
        const error = MontyDisposedError();
        expect(error.message, 'Interpreter disposed during execution');
      });

      test('construction with custom message', () {
        const error = MontyDisposedError('disposed early');
        expect(error.message, 'disposed early');
      });

      test('toString', () {
        const error = MontyDisposedError();
        expect(
          error.toString(),
          'MontyDisposedError: Interpreter disposed during execution',
        );
      });
    });

    group('MontyResourceError', () {
      test('construction', () {
        const error = MontyResourceError('out of memory');
        expect(error.message, 'out of memory');
      });

      test('toString', () {
        const error = MontyResourceError('timeout exceeded');
        expect(error.toString(), 'MontyResourceError: timeout exceeded');
      });
    });

    group('pattern matching exhaustiveness', () {
      test('switch covers all subtypes', () {
        final errors = <MontyError>[
          const MontyScriptError('script'),
          const MontyPanicError('panic'),
          const MontyCrashError(),
          const MontyDisposedError(),
          const MontyResourceError('oom'),
        ];

        for (final error in errors) {
          final label = switch (error) {
            MontyScriptError() => 'script',
            MontyPanicError() => 'panic',
            MontyCrashError() => 'crash',
            MontyDisposedError() => 'disposed',
            MontyResourceError() => 'resource',
          };
          expect(label, isNotEmpty);
        }
      });

      test('catch as MontyError works for all subtypes', () {
        void throwError(MontyError e) => throw e;

        expect(
          () => throwError(const MontyScriptError('s')),
          throwsA(isA<MontyError>()),
        );
        expect(
          () => throwError(const MontyPanicError('p')),
          throwsA(isA<MontyError>()),
        );
        expect(
          () => throwError(const MontyCrashError()),
          throwsA(isA<MontyError>()),
        );
        expect(
          () => throwError(const MontyDisposedError()),
          throwsA(isA<MontyError>()),
        );
        expect(
          () => throwError(const MontyResourceError('r')),
          throwsA(isA<MontyError>()),
        );
      });
    });
  });
}
