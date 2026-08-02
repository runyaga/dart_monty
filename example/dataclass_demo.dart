// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
// User leads the file for readability; MontyCallback's signature is
// `Future<Object?>` per the typedef so the lambda can't be sync.
// ignore_for_file: prefer-match-file-name, avoid-unnecessary-futures
/// Stateful dataclass round-trip through `MontyRuntime`.
///
/// `MontyRuntime` keeps Python state across `execute()` calls, so a
/// dataclass produced by one call remains a live Python object on the
/// next call. The bridge round-trip preserves the typed
/// `MontyDataclass` so the Dart side can hydrate it into a user class.
///
/// Core's `dart_monty_core/example/10_dataclasses.dart` covers the
/// per-call hydration mechanics with `Monty(code).run`. This demo
/// shows the part `MontyRuntime` adds: durable state across calls,
/// observable through ordinary Python attribute access in user code.
///
/// Works on every backend dart_monty_core ships (native FFI, WASM,
/// dart2js).
///
/// Run:
///   dart run example/dataclass_demo.dart
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

class User {
  const User({required this.name, required this.age});

  factory User.fromAttrs(Map<String, Object?> a) =>
      User(name: a['name']! as String, age: a['age']! as int);

  final String name;
  final int age;

  @override
  String toString() => 'User(name=$name, age=$age)';
}

// Say it with the type, not with a hand-built envelope.
//
// dart_monty_core 0.19 routes host callback returns through
// `MontyValue.encodeForWire`, so a Map spelling `{'__type': 'dataclass', ...}`
// by hand is no longer honoured as a dataclass — it arrives in Python as a
// plain dict, `user.name` reads as null, and the cast below throws. Returning a
// `MontyDataclass` is the documented replacement (core CHANGELOG, 0.19.0
// Breaking).
MontyDataclass _userValue({required String name, required int age}) =>
    MontyDataclass(
      name: 'User',
      typeId: 1,
      fieldNames: const ['name', 'age'],
      attrs: {'name': MontyString(name), 'age': MontyInt(age)},
    );

Future<void> main() async {
  final runtime = MontyRuntime()
    ..register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'make_user',
          description: 'Construct a User dataclass.',
          params: [
            HostParam(name: 'name', type: HostParamType.string),
            HostParam(name: 'age', type: HostParamType.integer),
          ],
        ),
        handler: (args, _) async => _userValue(
          name: args['name']! as String,
          age: args['age']! as int,
        ),
      ),
    );

  // 1. Construct and bind the dataclass in Python state. The assignment
  //    has no return value, but `user` now lives in the runtime's heap.
  await runtime.execute('user = make_user(name="alice", age=30)').result;
  print('── 1. user = make_user(...) ──');

  // 2. Access an attribute on a *later* execute call. This only works
  //    because `user` survived as a real Python object — not a serialized
  //    envelope rebuilt from JSON each call.
  final nameResult = await runtime.execute('user.name').result;
  print('── 2. user.name ──');
  print('   value: ${nameResult.value.dartValue}'); // alice

  // 3. Return the whole dataclass. The bridge preserves the typed
  //    MontyDataclass through to the result so the host can hydrate.
  final fullResult = await runtime.execute('user').result;
  final dc = fullResult.value as MontyDataclass;
  print('── 3. user ──');
  // Expected: typed = MontyDataclass, hydrated = User(name=alice, age=30)
  print('   typed:    ${dc.runtimeType}');
  print('   hydrated: ${dc.hydrate(User.fromAttrs)}');

  // 4. Replace the binding and confirm subsequent reads see the new one.
  await runtime.execute('user = make_user(name="bob", age=42)').result;
  final replaced = await runtime.execute('user').result;
  final replacedDc = replaced.value as MontyDataclass;
  print('── 4. after re-binding ──');
  // Expected: User(name=bob, age=42)
  print('   hydrated: ${replacedDc.hydrate(User.fromAttrs)}');

  await runtime.dispose();
}
