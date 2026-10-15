/// A host class for tests: a `User` dataclass whose instances a host
/// function returns as `ClassInstance` values.
library;

import 'package:dart_monty_core/dart_monty_core.dart';

/// A host-side user record.
final class User {
  const User(this.name, this.age);

  final String name;
  final int age;
}

/// `User` as a Python dataclass: its fields read from the Dart object.
final userClass = HostClass<User>(
  'User',
  isDataclass: true,
  instance: (
    fields: {'name': (u) => MontyString(u.name), 'age': (u) => MontyInt(u.age)},
    properties: const {},
    methods: const {},
  ),
);

/// [name] and [age] as a `User` instance the session holds.
ClassInstance<User> userInstance(String name, int age) => ClassInstance(
  User(name, age),
  classType: ClassType(userClass),
  policies: (eagerAttrs: 'all', lazyAttrs: null, allowedMethods: null),
);
