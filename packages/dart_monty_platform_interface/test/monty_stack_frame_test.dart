import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MontyStackFrame', () {
    group('fromJson', () {
      test('parses full JSON', () {
        final frame = MontyStackFrame.fromJson(const {
          'filename': 'app.py',
          'start_line': 5,
          'start_column': 8,
          'end_line': 5,
          'end_column': 25,
          'frame_name': '<module>',
          'preview_line': 'result = compute(x)',
          'hide_caret': true,
          'hide_frame_name': false,
        });
        expect(frame.filename, 'app.py');
        expect(frame.startLine, 5);
        expect(frame.startColumn, 8);
        expect(frame.endLine, 5);
        expect(frame.endColumn, 25);
        expect(frame.frameName, '<module>');
        expect(frame.previewLine, 'result = compute(x)');
        expect(frame.hideCaret, isTrue);
        expect(frame.hideFrameName, isFalse);
      });

      test('parses minimal JSON', () {
        final frame = MontyStackFrame.fromJson(const {
          'filename': 'x.py',
          'start_line': 1,
          'start_column': 0,
        });
        expect(frame.filename, 'x.py');
        expect(frame.startLine, 1);
        expect(frame.startColumn, 0);
        expect(frame.endLine, isNull);
        expect(frame.endColumn, isNull);
        expect(frame.frameName, isNull);
        expect(frame.previewLine, isNull);
        expect(frame.hideCaret, isFalse);
        expect(frame.hideFrameName, isFalse);
      });
    });

    group('toJson', () {
      test('serializes all fields', () {
        const frame = MontyStackFrame(
          filename: 'lib.py',
          startLine: 7,
          startColumn: 2,
          endLine: 9,
          endColumn: 15,
          frameName: 'helper',
          previewLine: '  x = 1',
          hideCaret: true,
          hideFrameName: true,
        );
        expect(frame.toJson(), {
          'filename': 'lib.py',
          'start_line': 7,
          'start_column': 2,
          'end_line': 9,
          'end_column': 15,
          'frame_name': 'helper',
          'preview_line': '  x = 1',
          'hide_caret': true,
          'hide_frame_name': true,
        });
      });

      test('omits null and default-false fields', () {
        const frame = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        expect(frame.toJson(), {
          'filename': 'a.py',
          'start_line': 1,
          'start_column': 0,
        });
      });
    });

    test('JSON round-trip with all fields', () {
      const original = MontyStackFrame(
        filename: 'round.py',
        startLine: 3,
        startColumn: 4,
        endLine: 3,
        endColumn: 10,
        frameName: 'foo',
        previewLine: '    foo()',
        hideCaret: true,
        hideFrameName: true,
      );
      final restored = MontyStackFrame.fromJson(original.toJson());
      expect(restored, original);
    });

    test('JSON round-trip with minimal fields', () {
      const original = MontyStackFrame(
        filename: 'min.py',
        startLine: 1,
        startColumn: 0,
      );
      final restored = MontyStackFrame.fromJson(original.toJson());
      expect(restored, original);
    });

    group('equality', () {
      test('equal when all fields match', () {
        const a = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
          frameName: 'fn',
        );
        const b = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
          frameName: 'fn',
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('not equal when filename differs', () {
        const a = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        const b = MontyStackFrame(
          filename: 'b.py',
          startLine: 1,
          startColumn: 0,
        );
        expect(a, isNot(b));
      });

      test('not equal when startLine differs', () {
        const a = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        const b = MontyStackFrame(
          filename: 'a.py',
          startLine: 2,
          startColumn: 0,
        );
        expect(a, isNot(b));
      });

      test('not equal when hideCaret differs', () {
        const a = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        const b = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
          hideCaret: true,
        );
        expect(a, isNot(b));
      });

      test('not equal to other types', () {
        const frame = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        expect(frame, isNot('a.py'));
      });

      test('identical instances are equal', () {
        const frame = MontyStackFrame(
          filename: 'a.py',
          startLine: 1,
          startColumn: 0,
        );
        expect(frame == frame, isTrue);
      });
    });

    test('toString', () {
      const frame = MontyStackFrame(
        filename: 'main.py',
        startLine: 42,
        startColumn: 8,
      );
      expect(frame.toString(), 'MontyStackFrame(main.py:42:8)');
    });

    group('listFromJson', () {
      test('parses list of frames', () {
        final frames = MontyStackFrame.listFromJson(const [
          {'filename': 'a.py', 'start_line': 1, 'start_column': 0},
          {
            'filename': 'b.py',
            'start_line': 5,
            'start_column': 4,
            'frame_name': 'fn',
          },
        ]);
        expect(frames, hasLength(2));
        expect(frames[0].filename, 'a.py');
        expect(frames[1].frameName, 'fn');
      });

      test('parses empty list', () {
        final frames = MontyStackFrame.listFromJson(const []);
        expect(frames, isEmpty);
      });
    });

    group('malformed JSON', () {
      test('throws on missing filename', () {
        expect(
          () => MontyStackFrame.fromJson(const {
            'start_line': 1,
            'start_column': 0,
          }),
          throwsA(isA<TypeError>()),
        );
      });

      test('throws on missing start_line', () {
        expect(
          () => MontyStackFrame.fromJson(const {
            'filename': 'a.py',
            'start_column': 0,
          }),
          throwsA(isA<TypeError>()),
        );
      });

      test('throws on missing start_column', () {
        expect(
          () => MontyStackFrame.fromJson(const {
            'filename': 'a.py',
            'start_line': 1,
          }),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
