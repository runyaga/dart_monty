// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
// User/Order classes appear first for readability; the MontyCallback
// signature is `Future<Object?>` per the typedef, so the lambdas can't
// be sync.
// ignore_for_file: prefer-match-file-name, avoid-unnecessary-futures
/// Dataclass hydration — Python `@dataclass` values returned through
/// dart_monty round-trip into typed Dart objects via
/// `MontyDataclass.hydrate(factory)`.
///
/// Works on every backend dart_monty_core ships (native FFI, WASM,
/// dart2js) — the dataclass envelope is platform-agnostic.
///
/// This demo uses `Monty.exec` with `externalFunctions:` because the
/// `MontyRuntime` + `HostFunction` bridge path currently coerces the
/// dataclass envelope to `MontyDict` on the way back (see issue
/// referenced in the README). When that lands, this demo will be
/// expanded with a bridge-side variant.
///
/// Run:
///   dart run example/dataclass_demo.dart
library;

import 'package:dart_monty/dart_monty.dart';

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

// ── Helper: build the dataclass envelope returned from a Dart callback. ─────

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
  await _readingFields();
  await _hydrateOne();
  await _hydrateRegistry();
}

// ── 1. Read fields directly off MontyDataclass. ─────────────────────────────
Future<void> _readingFields() async {
  print('── reading fields ──');

  final r = await Monty.exec(
    'make_user("alice", 30)',
    externalFunctions: {
      'make_user': (args) async => _dataclass(
        name: 'User',
        typeId: 1,
        attrs: {'name': args['_0']! as String, 'age': args['_1']! as int},
      ),
    },
  );

  final dc = r.value as MontyDataclass;
  print('  name:      ${dc.name}');                // User
  print('  fields:    ${dc.fieldNames}');          // [name, age]
  print('  frozen:    ${dc.frozen}');              // false
  print('  dartAttrs: ${dc.dartAttrs}');           // {name: alice, age: 30}
}

// ── 2. Hydrate into a user-supplied Dart class via a factory. ───────────────
Future<void> _hydrateOne() async {
  print('\n── hydrate (one type) ──');

  final r = await Monty.exec(
    'make_user("bob", 42)',
    externalFunctions: {
      'make_user': (args) async => _dataclass(
        name: 'User',
        typeId: 1,
        attrs: {'name': args['_0']! as String, 'age': args['_1']! as int},
      ),
    },
  );

  final user = (r.value as MontyDataclass).hydrate(User.fromAttrs);
  print('  $user');                                // User(name=bob, age=42)
}

// ── 3. Caller-side registry dispatching multiple dataclass types. ───────────
Future<void> _hydrateRegistry() async {
  print('\n── hydrate (registry) ──');

  final factories = <String, Object Function(Map<String, Object?>)>{
    'User': User.fromAttrs,
    'Order': Order.fromAttrs,
  };

  Object? hydrate(MontyValue value) {
    if (value is! MontyDataclass) return value;
    final factory = factories[value.name];

    return factory == null ? value : factory(value.dartAttrs);
  }

  final externalFunctions = <String, MontyCallback>{
    'make_user': (_) async => _dataclass(
      name: 'User',
      typeId: 1,
      attrs: {'name': 'carol', 'age': 7},
    ),
    'make_order': (_) async => _dataclass(
      name: 'Order',
      typeId: 2,
      attrs: {'id': 99, 'total': 12.5},
    ),
  };

  final ru = await Monty.exec(
    'make_user()',
    externalFunctions: externalFunctions,
  );
  final ro = await Monty.exec(
    'make_order()',
    externalFunctions: externalFunctions,
  );

  print('  ${hydrate(ru.value)}'); // User(name=carol, age=7)
  print('  ${hydrate(ro.value)}'); // Order(id=99, total=12.5)
}
