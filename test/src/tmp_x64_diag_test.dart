@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// TEMPORARY diagnostic. Prints only; always passes. Deleted once it has
// reported. `dataclass_demo` fails on linux-x64 CI but passes on macOS-arm64
// and linux-arm64: the host-returned MontyDataclass never binds, so `user.name`
// is null and `user` comes back MontyNone. This narrows WHICH layer drops it.
void main() {
  test('DIAG host MontyDataclass round-trip', () async {
    print('DIAG arch=${Platform.version} os=${Platform.operatingSystem}');

    const dc = MontyDataclass(
      name: 'User',
      typeId: 1,
      fieldNames: ['name', 'age'],
      attrs: {'name': MontyString('alice'), 'age': MontyInt(30)},
    );
    // Layer 1: does the Dart side encode it correctly on this arch?
    print('DIAG toJson=${dc.toJson()}');
    print('DIAG encodeForWire=${MontyValue.encodeForWire(dc)}');

    final runtime = MontyRuntime()
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'make_user',
            description: 'Construct a User dataclass.',
            params: [HostParam(name: 'name', type: HostParamType.string)],
          ),
          handler: (args, _) async => dc,
        ),
      );

    // Layer 2: does the assignment succeed? dataclass_demo ignores this error.
    final r1 = await runtime.execute('user = make_user(name="alice")').result;
    print('DIAG assign error=${r1.error}');

    // Layer 3: what does Python think it received?
    final r2 = await runtime
        .execute('{"t": type(user).__name__, "r": repr(user)}')
        .result;
    print('DIAG inspect error=${r2.error} value=${r2.value.dartValue}');

    // Layer 4: the read dataclass_demo actually casts.
    final r3 = await runtime.execute('user').result;
    print('DIAG read type=${r3.value.runtimeType} error=${r3.error}');

    await runtime.dispose();
  });
}
