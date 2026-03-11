// Tests exercise the deprecated singleton API intentionally.
// ignore_for_file: deprecated_member_use_from_same_package
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('MockMontyPlatform', () {
    late MockMontyPlatform mock;

    setUp(() {
      mock = MockMontyPlatform();
    });

    tearDown(MontyPlatform.resetInstance);

    test('can be registered as MontyPlatform.instance', () {
      MontyPlatform.instance = mock;
      expect(MontyPlatform.instance, mock);
    });
  });
}
