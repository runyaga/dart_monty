// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
// User leads the file for readability.
// ignore_for_file: prefer-match-file-name
/// A dataclass-like host value that persists across `execute()` calls.
///
/// A host function returns a Dart `User` wrapped in core's [ClassInstance],
/// described by a [HostClass] marked as a dataclass. Python sees an object
/// whose fields read as ordinary attributes. Because `MontyRuntime` keeps
/// one session across `execute()` calls, the object bound by one call is
/// still a live Python object on the next.
///
/// An instance the sandbox hands back decodes to the same [ClassInstance],
/// so `dartValue` is the original Dart `User`: no rebuilding from fields.
///
/// Core's `example/10_dataclasses.dart` covers the other direction: a
/// dataclass defined in Python reaching Dart as a `MontyClassProxy`.
///
/// Run:
///   dart run example/dataclass_demo.dart
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show ClassInstance, ClassType, HostClass;

class User {
  const User({required this.name, required this.age});

  final String name;
  final int age;

  @override
  String toString() => 'User(name=$name, age=$age)';
}

/// `User` as a Python dataclass with two fields.
const _userClass = HostClass<User>(
  'User',
  isDataclass: true,
  instance: (
    fields: {'name': _name, 'age': _age},
    properties: <String, Object Function(User)>{},
    methods: <String, Never>{},
  ),
);

// A field's value crosses as a MontyValue.
Object _name(User u) => MontyString(u.name);
Object _age(User u) => MontyInt(u.age);

final ClassType<User> _userType = ClassType(_userClass);

/// [user] as a session value whose fields cross eagerly.
ClassInstance<User> _userValue(User user) => ClassInstance(
  user,
  classType: _userType,
  policies: (eagerAttrs: 'all', lazyAttrs: null, allowedMethods: null),
);

Future<void> main() async {
  final worker = Platform.environment['DART_MONTY_WORKER'];
  final pool = await Monty.start(
    workerLocation: worker == null || worker.isEmpty ? null : worker,
  );
  final runtime = await MontyRuntime.start(pool: pool);
  runtime.register(
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
        User(
          name: (args['name']! as MontyString).value,
          age: (args['age']! as MontyInt).value,
        ),
      ),
    ),
  );

  try {
    // 1. Construct and bind the object in Python state. The assignment has
    //    no return value, but `user` now lives in the session's heap.
    await runtime.execute('user = make_user(name="alice", age=30)').result;
    print('── 1. user = make_user(...) ──');

    // 2. Access an attribute on a *later* execute call. This only works
    //    because `user` survived as a live Python object.
    final name = await runtime.execute('user.name').result;
    print('── 2. user.name ──');
    print('   value: ${name.dartValue}'); // alice
    _check(name == const MontyString('alice'), 'user.name');

    // 3. Return the whole object. It decodes to the ClassInstance the host
    //    sent, so dartValue is the Dart User itself.
    final full = await runtime.execute('user').result;
    print('── 3. user ──');
    // Expected: typed = ClassInstance<User>, value = User(name=alice, age=30)
    print('   typed: ${full.runtimeType}');
    print('   value: ${full.dartValue}');
    _check(full.dartValue is User, 'user is a User');

    // 4. Replace the binding and confirm later reads see the new one.
    await runtime.execute('user = make_user(name="bob", age=42)').result;
    final replaced = await runtime.execute('user').result;
    print('── 4. after re-binding ──');
    // Expected: User(name=bob, age=42)
    print('   value: ${replaced.dartValue}');
    final age = await runtime.execute('user.age + 1').result;
    _check(age == const MontyInt(43), 'user.age + 1');
  } finally {
    await runtime.dispose();
    await pool.close();
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
