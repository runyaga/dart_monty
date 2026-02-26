import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MontyException', () {
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
        expect(exception.excType, isNull);
        expect(exception.traceback, isEmpty);
      });

      test('parses JSON with excType', () {
        final exception = MontyException.fromJson(const {
          'message': 'division by zero',
          'exc_type': 'ZeroDivisionError',
        });
        expect(exception.excType, 'ZeroDivisionError');
        expect(exception.message, 'division by zero');
      });

      test('parses JSON with traceback', () {
        final exception = MontyException.fromJson(const {
          'message': 'name x is not defined',
          'exc_type': 'NameError',
          'traceback': [
            {
              'filename': 'script.py',
              'start_line': 1,
              'start_column': 0,
              'frame_name': '<module>',
            },
          ],
        });
        expect(exception.excType, 'NameError');
        final traceback = exception.traceback;
        expect(traceback, hasLength(1));
        expect(traceback.first.filename, 'script.py');
        expect(traceback.first.frameName, '<module>');
      });

      test('parses JSON with empty traceback', () {
        final exception = MontyException.fromJson(const {
          'message': 'error',
          'traceback': <dynamic>[],
        });
        expect(exception.traceback, isEmpty);
      });

      test('parses JSON with null traceback', () {
        final exception = MontyException.fromJson(const {
          'message': 'error',
          'traceback': null,
        });
        expect(exception.traceback, isEmpty);
      });

      test('parses JSON with multi-frame traceback', () {
        final exception = MontyException.fromJson(const {
          'message': 'oops',
          'exc_type': 'RuntimeError',
          'traceback': [
            {
              'filename': 'main.py',
              'start_line': 10,
              'start_column': 0,
              'frame_name': '<module>',
            },
            {
              'filename': 'main.py',
              'start_line': 5,
              'start_column': 4,
              'frame_name': 'outer',
              'preview_line': '    inner()',
            },
            {
              'filename': 'main.py',
              'start_line': 2,
              'start_column': 8,
              'frame_name': 'inner',
              'preview_line': '        raise RuntimeError("oops")',
              'hide_caret': true,
            },
          ],
        });
        expect(exception.traceback, hasLength(3));
        expect(exception.traceback[2].hideCaret, isTrue);
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

      test('serializes excType', () {
        const exception = MontyException(
          message: 'bad',
          excType: 'ValueError',
        );
        final json = exception.toJson();
        expect(json['exc_type'], 'ValueError');
      });

      test('serializes traceback', () {
        const exception = MontyException(
          message: 'err',
          traceback: [
            MontyStackFrame(
              filename: 'a.py',
              startLine: 1,
              startColumn: 0,
            ),
          ],
        );
        final json = exception.toJson();
        expect(json['traceback'], isA<List<dynamic>>());
        final frames = json['traceback'] as List<dynamic>;
        expect(frames, hasLength(1));
      });

      test('omits empty traceback', () {
        const exception = MontyException(message: 'err');
        final json = exception.toJson();
        expect(json.containsKey('traceback'), isFalse);
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

    test('JSON round-trip with excType and traceback', () {
      const original = MontyException(
        message: 'invalid literal',
        excType: 'ValueError',
        filename: 'script.py',
        lineNumber: 3,
        traceback: [
          MontyStackFrame(
            filename: 'script.py',
            startLine: 1,
            startColumn: 0,
            frameName: '<module>',
          ),
          MontyStackFrame(
            filename: 'script.py',
            startLine: 3,
            startColumn: 4,
            frameName: 'parse',
            previewLine: '    int("abc")',
          ),
        ],
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

      test('not equal when excType differs', () {
        const a = MontyException(
          message: 'err',
          excType: 'ValueError',
        );
        const b = MontyException(
          message: 'err',
          excType: 'TypeError',
        );
        expect(a, isNot(b));
      });

      test('not equal when traceback differs', () {
        const a = MontyException(
          message: 'err',
          traceback: [
            MontyStackFrame(
              filename: 'a.py',
              startLine: 1,
              startColumn: 0,
            ),
          ],
        );
        const b = MontyException(
          message: 'err',
          traceback: [
            MontyStackFrame(
              filename: 'b.py',
              startLine: 1,
              startColumn: 0,
            ),
          ],
        );
        expect(a, isNot(b));
      });

      test('equal with same traceback', () {
        const a = MontyException(
          message: 'err',
          excType: 'ValueError',
          traceback: [
            MontyStackFrame(
              filename: 'a.py',
              startLine: 1,
              startColumn: 0,
            ),
          ],
        );
        const b = MontyException(
          message: 'err',
          excType: 'ValueError',
          traceback: [
            MontyStackFrame(
              filename: 'a.py',
              startLine: 1,
              startColumn: 0,
            ),
          ],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
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

      test('with excType', () {
        const exception = MontyException(
          message: 'division by zero',
          excType: 'ZeroDivisionError',
        );
        expect(
          exception.toString(),
          'MontyException: ZeroDivisionError: division by zero',
        );
      });

      test('with filename', () {
        const exception = MontyException(
          message: 'err',
          filename: 'main.py',
        );
        expect(exception.toString(), 'MontyException: err (main.py)');
      });

      test('with excType and filename', () {
        const exception = MontyException(
          message: 'err',
          excType: 'ValueError',
          filename: 'main.py',
          lineNumber: 5,
        );
        expect(
          exception.toString(),
          'MontyException: ValueError: err (main.py:5)',
        );
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
