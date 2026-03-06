@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_native/dart_monty_native.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Integration tests for [IsolatePlugin] with a real [MontyNative] backend.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_native
/// dart test --tags=integration test/integration/isolate_plugin_test.dart
/// ```
void main() {
  final libPath = _resolveLibraryPath();

  MontyNative createMonty() =>
      MontyNative(bindings: NativeIsolateBindingsImpl(libraryPath: libPath));

  group('IsolatePlugin integration', () {
    test('child return value round-trip', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');

      final handle = await spawn({'code': '40 + 2'});
      final result = await await_({'handle': handle! as int});

      expect(result, 42);

      await plugin.onDispose();
    });

    test('child print output round-trip', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');
      final getOutput = _findHandler(plugin, 'isolate_get_output');

      final handle = await spawn({'code': 'print("hello from child")'});
      await await_({'handle': handle! as int});

      final output = await getOutput({'handle': handle as int});
      expect(output, contains('hello from child'));

      await plugin.onDispose();
    });

    test('child with no print output returns null', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');
      final getOutput = _findHandler(plugin, 'isolate_get_output');

      final handle = await spawn({'code': '1 + 1'});
      await await_({'handle': handle! as int});

      final output = await getOutput({'handle': handle as int});
      expect(output, isNull);

      await plugin.onDispose();
    });

    test('multi-child output isolation', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');
      final getOutput = _findHandler(plugin, 'isolate_get_output');

      final h0 = await spawn({'code': 'print("alpha")'});
      final h1 = await spawn({'code': 'print("bravo")'});

      await await_({'handle': h0! as int});
      await await_({'handle': h1! as int});

      final out0 = await getOutput({'handle': h0 as int});
      final out1 = await getOutput({'handle': h1 as int});

      expect(out0, contains('alpha'));
      expect(out0, isNot(contains('bravo')));
      expect(out1, contains('bravo'));
      expect(out1, isNot(contains('alpha')));

      await plugin.onDispose();
    });

    test('multi-child return value isolation', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');

      final h0 = await spawn({'code': '100'});
      final h1 = await spawn({'code': '"hello"'});

      final r0 = await await_({'handle': h0! as int});
      final r1 = await await_({'handle': h1! as int});

      expect(r0, 100);
      expect(r1, 'hello');

      await plugin.onDispose();
    });

    test('child with both return value and print output', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');
      final getOutput = _findHandler(plugin, 'isolate_get_output');

      final handle = await spawn({
        'code': 'print("side effect")\n42',
      });
      final result = await await_({'handle': handle! as int});
      final output = await getOutput({'handle': handle as int});

      expect(result, 42);
      expect(output, contains('side effect'));

      await plugin.onDispose();
    });

    test('failed child propagates error', () async {
      final plugin = IsolatePlugin(platformFactory: () async => createMonty());
      final spawn = _findHandler(plugin, 'isolate_spawn');
      final await_ = _findHandler(plugin, 'isolate_await');

      final handle = await spawn({'code': 'undefined_var'});

      Object? caughtError;
      try {
        await await_({'handle': handle! as int});
      } on StateError catch (e) {
        caughtError = e;
      }

      expect(caughtError, isA<StateError>());
      expect(
        (caughtError! as StateError).message,
        contains('failed'),
      );

      await plugin.onDispose();
    });
  });
}

HostFunctionHandler _findHandler(IsolatePlugin plugin, String name) {
  return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';

  return '../../native/target/release/libdart_monty_native.$ext';
}
