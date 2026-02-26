import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// A valid platform implementation that extends MontyPlatform.
class _TestMontyPlatform extends MontyPlatform {}

/// An invalid implementation using `implements` instead of `extends`.
class _ImplementsMontyPlatform implements MontyPlatform {
  // Provide a noSuchMethod so we don't need stubs for everything.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MontyPlatform', () {
    tearDown(MontyPlatform.resetInstance);

    group('instance', () {
      test('throws StateError when not set', () {
        expect(
          () => MontyPlatform.instance,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('has not been set'),
            ),
          ),
        );
      });

      test('returns instance after being set', () {
        final platform = _TestMontyPlatform();
        MontyPlatform.instance = platform;
        expect(MontyPlatform.instance, platform);
      });

      test('can be replaced', () {
        final first = _TestMontyPlatform();
        final second = _TestMontyPlatform();
        MontyPlatform.instance = first;
        MontyPlatform.instance = second;
        expect(MontyPlatform.instance, second);
      });
    });

    test('resetInstance clears the instance', () {
      MontyPlatform.instance = _TestMontyPlatform();
      MontyPlatform.resetInstance();
      expect(
        () => MontyPlatform.instance,
        throwsA(isA<StateError>()),
      );
    });

    test('rejects implements without extends', () {
      expect(
        () => MontyPlatform.instance = _ImplementsMontyPlatform(),
        throwsA(isA<AssertionError>()),
      );
    });

    group('default method implementations throw UnimplementedError', () {
      late MontyPlatform platform;

      setUp(() {
        platform = _TestMontyPlatform();
      });

      test('run() throws', () {
        expect(
          () => platform.run('code'),
          throwsUnimplementedError,
        );
      });

      test('start() throws', () {
        expect(
          () => platform.start('code'),
          throwsUnimplementedError,
        );
      });

      test('resume() throws', () {
        expect(
          () => platform.resume(null),
          throwsUnimplementedError,
        );
      });

      test('resumeWithError() throws', () {
        expect(
          () => platform.resumeWithError('error'),
          throwsUnimplementedError,
        );
      });

      test('dispose() throws', () {
        expect(
          () => platform.dispose(),
          throwsUnimplementedError,
        );
      });
    });
  });
}
