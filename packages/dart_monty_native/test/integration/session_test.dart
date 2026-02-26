@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty_native/dart_monty_native.dart';
import 'package:dart_monty_platform_interface/src/monty_session.dart';
import 'package:test/test.dart';

/// Integration tests for [MontySession] with real [MontyNative] backend.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_native
/// dart test --tags=integration test/integration/session_test.dart
/// ```
void main() {
  final libPath = _resolveLibraryPath();

  MontyNative createMonty() =>
      MontyNative(bindings: NativeIsolateBindingsImpl(libraryPath: libPath));

  test('state persistence across calls', () async {
    final monty = createMonty();
    final session = MontySession(platform: monty);

    await session.run('x = 42');
    final result = await session.run('x + 1');

    expect(result.value, 43);
    expect(result.isError, isFalse);

    session.dispose();
    await monty.dispose();
  });

  test('multi-type persistence', () async {
    final monty = createMonty();
    final session = MontySession(platform: monty);

    await session.run(
      'nums = [1,2,3]; name = "test"; flag = True',
    );
    final result = await session.run('[nums, name, flag]');

    expect(result.value, [
      [1, 2, 3],
      'test',
      true,
    ]);

    session.dispose();
    await monty.dispose();
  });

  test('error recovery preserves previous state', () async {
    final monty = createMonty();
    final session = MontySession(platform: monty);

    await session.run('x = 10');

    final errorResult = await session.run('1/0');
    expect(errorResult.isError, isTrue);

    final result = await session.run('x');
    expect(result.value, 10);

    session.dispose();
    await monty.dispose();
  });

  test('session isolation', () async {
    final montyA = createMonty();
    final montyB = createMonty();
    final sessionA = MontySession(platform: montyA);
    final sessionB = MontySession(platform: montyB);

    await sessionA.run('x = 1');

    final resultB = await sessionB.run('x');
    expect(resultB.isError, isTrue);
    expect(resultB.error!.message, contains('x'));

    sessionA.dispose();
    sessionB.dispose();
    await montyA.dispose();
    await montyB.dispose();
  });

  test('concurrent sessions', () async {
    final montyA = createMonty();
    final montyB = createMonty();
    final sessionA = MontySession(platform: montyA);
    final sessionB = MontySession(platform: montyB);

    await Future.wait([
      sessionA.run('x = 1'),
      sessionB.run('x = 2'),
    ]);

    final resultA = await sessionA.run('x');
    final resultB = await sessionB.run('x');

    expect(resultA.value, 1);
    expect(resultB.value, 2);

    sessionA.dispose();
    sessionB.dispose();
    await montyA.dispose();
    await montyB.dispose();
  });

  test('clearState resets for next run', () async {
    final monty = createMonty();
    final session = MontySession(platform: monty);

    await session.run('x = 42');
    session.clearState();

    final result = await session.run('x');
    expect(result.isError, isTrue);
    expect(result.error!.message, contains('x'));

    session.dispose();
    await monty.dispose();
  });

  test('non-serializable values silently dropped', () async {
    final monty = createMonty();
    final session = MontySession(platform: monty);

    // Functions are not JSON-serializable; they should be dropped.
    await session.run('def greet(): return "hi"\nx = 42');

    final state = session.state;
    expect(state['x'], 42);
    expect(state.containsKey('greet'), isFalse);

    session.dispose();
    await monty.dispose();
  });
}

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';

  return '../../native/target/release/libdart_monty_native.$ext';
}
