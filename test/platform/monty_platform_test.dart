import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

/// A valid platform implementation that extends MontyPlatform.
class _TestMontyPlatform extends MontyPlatform {}

void main() {
  group('MontyPlatform', () {
    group('default method implementations throw UnimplementedError', () {
      late MontyPlatform platform;

      setUp(() {
        platform = _TestMontyPlatform();
      });

      test('run() throws', () {
        expect(() => platform.run('code'), throwsUnimplementedError);
      });

      test('start() throws', () {
        expect(() => platform.start('code'), throwsUnimplementedError);
      });

      test('resume() throws', () {
        expect(() => platform.resume(null), throwsUnimplementedError);
      });

      test('resumeWithError() throws', () {
        expect(
          () => platform.resumeWithError('error'),
          throwsUnimplementedError,
        );
      });

      test('dispose() throws', () {
        expect(() => platform.dispose(), throwsUnimplementedError);
      });
    });
  });
}
