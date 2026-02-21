import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MontyException', () {
    test('constructs with all fields', () {
      const exception = MontyException(
        message: 'SyntaxError',
        filename: 'main.py',
        lineNumber: 10,
        columnNumber: 5,
        sourceCode: 'x = 1 +',
      );
      expect(exception.message, 'SyntaxError');
      expect(exception.filename, 'main.py');
      expect(exception.lineNumber, 10);
      expect(exception.columnNumber, 5);
      expect(exception.sourceCode, 'x = 1 +');
    });

    test('constructs with message only', () {
      const exception = MontyException(message: 'error');
      expect(exception.message, 'error');
      expect(exception.filename, isNull);
      expect(exception.lineNumber, isNull);
      expect(exception.columnNumber, isNull);
      expect(exception.sourceCode, isNull);
    });

    test('implements Exception', () {
      const exception = MontyException(message: 'boom');
      expect(exception, isA<Exception>());
    });

    group('fromJson', () {
      test('parses full JSON', () {
        final exception = MontyException.fromJson(const {
          'message': 'NameError',
          'filename': 'test.py',
          'line_number': 3,
          'column_number': 1,
          'source_code': 'print(x)',
        });
        expect(exception.message, 'NameError');
        expect(exception.filename, 'test.py');
        expect(exception.lineNumber, 3);
        expect(exception.columnNumber, 1);
        expect(exception.sourceCode, 'print(x)');
      });

      test('parses minimal JSON', () {
        final exception = MontyException.fromJson(const {
          'message': 'error',
        });
        expect(exception.message, 'error');
        expect(exception.filename, isNull);
        expect(exception.lineNumber, isNull);
        expect(exception.columnNumber, isNull);
        expect(exception.sourceCode, isNull);
      });
    });

    group('toJson', () {
      test('serializes all fields', () {
        const exception = MontyException(
          message: 'TypeError',
          filename: 'lib.py',
          lineNumber: 7,
          columnNumber: 12,
          sourceCode: '1 + "a"',
        );
        expect(exception.toJson(), {
          'message': 'TypeError',
          'filename': 'lib.py',
          'line_number': 7,
          'column_number': 12,
          'source_code': '1 + "a"',
        });
      });

      test('omits null fields', () {
        const exception = MontyException(message: 'error');
        expect(exception.toJson(), {'message': 'error'});
      });
    });

    test('JSON round-trip', () {
      const original = MontyException(
        message: 'ValueError',
        filename: 'app.py',
        lineNumber: 42,
        columnNumber: 8,
        sourceCode: 'int("abc")',
      );
      final restored = MontyException.fromJson(original.toJson());
      expect(restored, original);
    });

    group('equality', () {
      test('equal when all fields match', () {
        const a = MontyException(message: 'err', filename: 'a.py');
        const b = MontyException(message: 'err', filename: 'a.py');
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('not equal when message differs', () {
        const a = MontyException(message: 'err1');
        const b = MontyException(message: 'err2');
        expect(a, isNot(b));
      });

      test('not equal when filename differs', () {
        const a = MontyException(message: 'err', filename: 'a.py');
        const b = MontyException(message: 'err', filename: 'b.py');
        expect(a, isNot(b));
      });

      test('not equal when lineNumber differs', () {
        const a = MontyException(message: 'err', lineNumber: 1);
        const b = MontyException(message: 'err', lineNumber: 2);
        expect(a, isNot(b));
      });

      test('not equal when columnNumber differs', () {
        const a = MontyException(message: 'err', columnNumber: 1);
        const b = MontyException(message: 'err', columnNumber: 2);
        expect(a, isNot(b));
      });

      test('not equal when sourceCode differs', () {
        const a = MontyException(message: 'err', sourceCode: 'x');
        const b = MontyException(message: 'err', sourceCode: 'y');
        expect(a, isNot(b));
      });

      test('not equal to other types', () {
        const exception = MontyException(message: 'err');
        expect(exception, isNot('err'));
      });

      test('identical instances are equal', () {
        const exception = MontyException(message: 'err');
        expect(exception == exception, isTrue);
      });
    });

    group('toString', () {
      test('message only', () {
        const exception = MontyException(message: 'boom');
        expect(exception.toString(), 'MontyException: boom');
      });

      test('with filename', () {
        const exception = MontyException(
          message: 'err',
          filename: 'main.py',
        );
        expect(exception.toString(), 'MontyException: err (main.py)');
      });

      test('with filename and line', () {
        const exception = MontyException(
          message: 'err',
          filename: 'main.py',
          lineNumber: 5,
        );
        expect(exception.toString(), 'MontyException: err (main.py:5)');
      });

      test('with filename, line, and column', () {
        const exception = MontyException(
          message: 'err',
          filename: 'main.py',
          lineNumber: 5,
          columnNumber: 3,
        );
        expect(exception.toString(), 'MontyException: err (main.py:5:3)');
      });
    });

    test('handles empty message', () {
      const exception = MontyException(message: '');
      expect(exception.message, '');
      expect(exception.toString(), 'MontyException: ');
    });

    test('handles long message', () {
      final longMsg = 'x' * 1000;
      final exception = MontyException(message: longMsg);
      expect(exception.message, longMsg);
    });

    group('malformed JSON', () {
      test('throws on missing message', () {
        expect(
          () => MontyException.fromJson(const <String, dynamic>{}),
          throwsA(isA<TypeError>()),
        );
      });

      test('throws on wrong message type', () {
        expect(
          () => MontyException.fromJson(const {'message': 123}),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
