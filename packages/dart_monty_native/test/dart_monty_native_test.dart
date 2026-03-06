import 'package:dart_monty_native/dart_monty_native.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registerWith sets MontyPlatform.instance to MontyNative', () {
    DartMontyNative.registerWith();

    expect(MontyPlatform.instance, isA<MontyNative>());
  });
}
