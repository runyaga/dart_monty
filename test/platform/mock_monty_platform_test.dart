import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('MockMontyPlatform', () {
    late MockMontyPlatform mock;

    setUp(() {
      mock = MockMontyPlatform();
    });

    test('is a MontyPlatform', () {
      expect(mock, isA<MontyPlatform>());
    });

    test('run() throws StateError when runResult is not set', () {
      expect(() => mock.run('code'), throwsStateError);
    });
  });
}
