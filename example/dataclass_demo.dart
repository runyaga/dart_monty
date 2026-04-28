// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
// User/Order classes lead the file for readability; MontyCallback's
// signature is `Future<Object?>` per the typedef so the lambdas can't
// be sync.
// ignore_for_file: prefer-match-file-name, avoid-unnecessary-futures
/// Dataclass hydration through `MontyRuntime` — Python `@dataclass`
/// values returned from a registered `HostFunction` round-trip into
/// typed Dart objects via `MontyDataclass.hydrate(factory)`.
///
/// Works on every backend dart_monty_core ships (native FFI, WASM,
/// dart2js) — the bridge surface is platform-agnostic.
///
/// Run:
///   dart run example/dataclass_demo.dart
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

// ── User-defined Dart classes the demo hydrates into. ───────────────────────

class User {
  const User({required this.name, required this.age});

  factory User.fromAttrs(Map<String, Object?> a) =>
      User(name: a['name']! as String, age: a['age']! as int);

  final String name;
  final int age;

  @override
  String toString() => 'User(name=$name, age=$age)';
}

class Order {
  const Order({required this.id, required this.total});

  factory Order.fromAttrs(Map<String, Object?> a) =>
      Order(id: a['id']! as int, total: (a['total']! as num).toDouble());

  final int id;
  final double total;

  @override
  String toString() => 'Order(id=$id, total=$total)';
}

// ── Helper: build the dataclass envelope returned from a HostFunction. ──────

Map<String, Object?> _dataclass({
  required String name,
  required int typeId,
  required Map<String, Object?> attrs,
}) => {
  '__type': 'dataclass',
  'name': name,
  'type_id': typeId,
  'field_names': attrs.keys.toList(),
  'attrs': attrs,
  'frozen': false,
};

Future<void> main() async {
  await _bridgeRoundTrip();
  await _hydrateRegistry();
}

// ── 1. HostFunction returns a dataclass envelope; MontyRuntime preserves
//      the typed MontyDataclass through to MontyResult.value.
Future<void> _bridgeRoundTrip() async {
  print('── bridge round-trip ──');

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
        handler: (args, _) async => _dataclass(
          name: 'User',
          typeId: 1,
          attrs: {'name': args['name'], 'age': args['age']},
        ),
      ),
    );

  final result = await runtime.execute(
    'make_user(name="alice", age=30)',
  ).result;
  final dc = result.value as MontyDataclass;

  print('  type:     ${dc.name}');                  // User
  print('  fields:   ${dc.fieldNames}');            // [name, age]
  print('  attrs:    ${dc.dartAttrs}');             // {name: alice, age: 30}

  final user = dc.hydrate(User.fromAttrs);
  print('  hydrated: $user');                       // User(name=alice, age=30)

  await runtime.dispose();
}

// ── 2. Registry pattern dispatching multiple dataclass types by name. ───────
Future<void> _hydrateRegistry() async {
  print('\n── registry dispatch ──');

  final factories = <String, Object Function(Map<String, Object?>)>{
    'User': User.fromAttrs,
    'Order': Order.fromAttrs,
  };

  Object? hydrate(MontyValue value) {
    if (value is! MontyDataclass) return value;
    final factory = factories[value.name];

    return factory == null ? value : factory(value.dartAttrs);
  }

  final runtime = MontyRuntime()
    ..register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'make_user',
          description: 'Construct a User.',
        ),
        handler: (_, _) async => _dataclass(
          name: 'User',
          typeId: 1,
          attrs: {'name': 'carol', 'age': 7},
        ),
      ),
    )
    ..register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'make_order',
          description: 'Construct an Order.',
        ),
        handler: (_, _) async => _dataclass(
          name: 'Order',
          typeId: 2,
          attrs: {'id': 99, 'total': 12.5},
        ),
      ),
    );

  final ru = await runtime.execute('make_user()').result;
  final ro = await runtime.execute('make_order()').result;

  print('  ${hydrate(ru.value)}'); // User(name=carol, age=7)
  print('  ${hydrate(ro.value)}'); // Order(id=99, total=12.5)

  await runtime.dispose();
}
