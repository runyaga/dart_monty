@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  test(
    'facade re-exports Frame, MontyRuntimeError, MontySyntaxError, '
    'MontyTypingError, MontyCrashedError, MontyExceptionValue and '
    'FrameTooLargeException',
    () {
      expect(
        [
          Frame,
          MontyRuntimeError,
          MontySyntaxError,
          MontyTypingError,
          MontyCrashedError,
          MontyExceptionValue,
          FrameTooLargeException,
        ],
        hasLength(7),
      );
    },
  );

  test(
    '1 / 0 throws MontyRuntimeError with traceback frame on line 1 through '
    'facade import',
    () async {
      try {
        await Monty.withPool(
          (m) => m.withSession((s) => s.feedRun('1 / 0')),
        );
        fail('expected MontyRuntimeError');
      } on MontyRuntimeError catch (e) {
        expect(e.exception.excType, 'ZeroDivisionError');
        final frames = e.traceback;
        expect(frames, hasLength(1));
        final frame = frames.firstOrNull;
        expect(frame, isA<Frame>());
        expect(frame?.line, 1);
        expect(e.display(), contains('ZeroDivisionError: division by zero'));
      }
    },
  );

  test('syntax error throws MontySyntaxError through facade import', () async {
    await expectLater(
      Monty.withPool((m) => m.withSession((s) => s.feedRun('def ('))),
      throwsA(
        isA<MontySyntaxError>().having(
          (e) => e.exception,
          'exception',
          isA<MontyExceptionValue>(),
        ),
      ),
    );
  });
}
