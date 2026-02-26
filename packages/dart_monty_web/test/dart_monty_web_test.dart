import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';
import 'package:dart_monty_web/dart_monty_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

void main() {
  group('DartMontyWeb', () {
    test('registerWith sets MontyPlatform.instance to MontyWasm', () {
      addTearDown(MontyPlatform.resetInstance);

      DartMontyWeb.registerWith(FakeRegistrar());

      expect(MontyPlatform.instance, isA<MontyWasm>());
    });
  });
}

class FakeRegistrar extends Fake implements Registrar {}
