// ignore_for_file: prefer-moving-to-variable, each execute is a feed.
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_typecheck_cases.dart';
import '_worker.dart';

void main() {
  late Monty pool;

  setUpAll(() async => pool = await startTestPool(maxProcesses: 4));
  tearDownAll(() => pool.close());

  test('type checking is off by default', () async {
    final runtime = await MontyRuntime.start(pool: pool);
    typecheckHostFunctions([]).forEach(runtime.register);
    try {
      await _expectRuntimeError(
        runtime.execute('get_trip()').result,
        'TypeError',
      );
      expect((await runtime.execute('x: int = "a"').result).dartValue, isNull);
      await _expectRuntimeError(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        'ValueError',
      );
    } finally {
      await runtime.dispose();
    }
  });

  test('skipTypeCheck affects one execute', () async {
    final runtime = await _runtime(pool);
    try {
      await runtime.execute('x: int = "a"', skipTypeCheck: true).result;
      expect(
        (await runtime.execute('x', skipTypeCheck: true).result).dartValue,
        'a',
      );
      await _expectCodes(runtime.execute('y: int = "b"').result, {
        'invalid-assignment',
      });
    } finally {
      await runtime.dispose();
    }
  });

  test('multi-turn definitions enter the checking context', () async {
    final runtime = await _runtime(pool);
    try {
      await runtime
          .execute(
            'def leg_count(r: Route) -> int:\n'
            '    return len(r["legs"])\n'
            'trip_id: str = "TR-10"',
          )
          .result;
      await _expectCodes(runtime.execute('leg_count(trip_id)').result, {
        'invalid-argument-type',
      });
      final value = await runtime
          .execute(
            'leg_count(plan_route(trip_id, "B2", {"max_leg_steps": 4, '
            '"avoid_cells": [], "require_chargers": True}))',
          )
          .result;
      expect(value.dartValue, 2);
    } finally {
      await runtime.dispose();
    }
  });

  test('runtime failure creates a known false-positive context gap', () async {
    final runtime = await _runtime(pool);
    try {
      await _expectRuntimeError(
        runtime.execute('z = 5\nraise ValueError("x")').result,
        'ValueError',
      );
      await _expectCodes(runtime.execute('w = z + 1').result, {
        'unresolved-reference',
      });
      expect(
        (await runtime.execute('w = z + 1', skipTypeCheck: true).result)
            .dartValue,
        isNull,
      );
    } finally {
      await runtime.dispose();
    }
  });

  test('a rejected program has no side effects', () async {
    final calls = <String>[];
    final runtime = await _runtime(pool, calls: calls);
    try {
      await runtime.execute('count: int = 0').result;
      calls.clear();
      await _expectCodes(
        runtime.execute('count = 1\nget_trip("TR-10")\nbad: int = "x"').result,
        {'invalid-assignment'},
      );
      expect(calls, isEmpty);
      expect(
        (await runtime.execute('count', skipTypeCheck: true).result).dartValue,
        0,
      );
      await _expectRuntimeError(
        runtime.execute('bad', skipTypeCheck: true).result,
        'NameError',
      );
    } finally {
      await runtime.dispose();
    }
  });

  test('checkpoint restore keeps checking stubs and context', () async {
    final runtime = await _runtime(pool);
    try {
      await runtime
          .execute('def leg_count(r: Route) -> int:\n    return len(r["legs"])')
          .result;
      final bytes = await runtime.checkpoint();
      await runtime.execute('ok: int = 1').result;
      await runtime.restore(bytes);
      await _expectCodes(runtime.execute('leg_count("x")').result, {
        'invalid-argument-type',
      });
      await _expectCodes(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        {'invalid-argument-type'},
      );
      await _expectCodes(runtime.execute('ok + 1').result, {
        'unresolved-reference',
      });
      await _expectRuntimeError(
        runtime.execute('ok + 1', skipTypeCheck: true).result,
        'NameError',
      );
      await _expectRuntimeError(
        runtime.execute('raise TimeoutError()').result,
        'TimeoutError',
      );
      await _expectCodes(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        {'invalid-argument-type'},
      );
    } finally {
      await runtime.dispose();
    }
  });

  test(
    'a restored dump carries its setting until the session is replaced',
    () async {
      final checked = await _runtime(pool);
      final unchecked = await _runtime(pool, checked: false);
      final checkedTarget = await MontyRuntime.start(pool: pool);
      typecheckHostFunctions([]).forEach(checkedTarget.register);
      final uncheckedTarget = await _runtime(pool);
      try {
        await checked.execute('seed: int = 1').result;
        await unchecked.execute('seed = 1').result;
        final checkedBytes = await checked.checkpoint();
        final uncheckedBytes = await unchecked.checkpoint();
        await checkedTarget.restore(checkedBytes);
        await uncheckedTarget.restore(uncheckedBytes);
        await _expectCodes(
          checkedTarget.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
          {'invalid-argument-type'},
        );
        await uncheckedTarget.execute('x: int = "a"').result;
        await _expectRuntimeError(
          checkedTarget
              .execute('raise TimeoutError()', skipTypeCheck: true)
              .result,
          'TimeoutError',
        );
        await _expectRuntimeError(
          checkedTarget.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
          'ValueError',
        );
      } finally {
        await checked.dispose();
        await unchecked.dispose();
        await checkedTarget.dispose();
        await uncheckedTarget.dispose();
      }
    },
  );

  test('error formats include diagnostic positions', () async {
    final jsonRuntime = await _runtime(pool);
    final conciseRuntime = await _runtime(pool, format: 'concise');
    final defaultRuntime = await _runtime(pool, format: null);
    try {
      final jsonError = await _typingError(
        jsonRuntime.execute('x = 1\ny: int = "a"').result,
      );
      final diagnostics = jsonDecode(jsonError.display())! as List<Object?>;
      final diagnostic = diagnostics.singleOrNull;
      expect(diagnostic, isNotNull);
      final location =
          (diagnostic! as Map<Object?, Object?>)['location']!
              as Map<Object?, Object?>;
      expect(location['row'], 2);
      expect(location['column'], isA<int>());
      final conciseError = await _typingError(
        conciseRuntime.execute('x = 1\ny: int = "a"').result,
      );
      expect(conciseError.display(), contains('main.py:2:'));
      final defaultError = await _typingError(
        defaultRuntime.execute('x = 1\ny: int = "a"').result,
      );
      expect(defaultError.display(), contains('main.py:2:'));
      expect(defaultError.display(), isNot(startsWith('[')));
    } finally {
      await jsonRuntime.dispose();
      await conciseRuntime.dispose();
      await defaultRuntime.dispose();
    }
  });

  test('sandbox mode checks each fresh execute', () async {
    final runtime = await _runtime(pool, sandbox: true);
    try {
      await _expectCodes(runtime.execute('x: int = "a"').result, {
        'invalid-assignment',
      });
      await _expectCodes(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        {'invalid-argument-type'},
      );
      await runtime.execute('y: int = 1').result;
      await _expectCodes(runtime.execute('z = y + 1').result, {
        'unresolved-reference',
      });
      await _expectRuntimeError(
        runtime.execute('z = y + 1', skipTypeCheck: true).result,
        'NameError',
      );
    } finally {
      await runtime.dispose();
    }
  });

  test('session replacement keeps checking', () async {
    final runtime = await _runtime(pool);
    try {
      await runtime.execute('old_name: int = 1').result;
      await _expectRuntimeError(
        runtime.execute('raise TimeoutError()').result,
        'TimeoutError',
      );
      await _expectCodes(runtime.execute('x: int = "a"').result, {
        'invalid-assignment',
      });
      await _expectCodes(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        {'invalid-argument-type'},
      );
      await _expectCodes(runtime.execute('old_name + 1').result, {
        'unresolved-reference',
      });
      await _expectRuntimeError(
        runtime.execute('old_name', skipTypeCheck: true).result,
        'NameError',
      );
    } finally {
      await runtime.dispose();
    }
  });

  test('clearState keeps checking', () async {
    final runtime = await _runtime(pool);
    try {
      await runtime.execute('old_name: int = 1').result;
      await runtime.clearState();
      await _expectCodes(runtime.execute('x: int = "a"').result, {
        'invalid-assignment',
      });
      await _expectCodes(
        runtime.execute('assign_crew("TR-10", "Pilot", "S-1")').result,
        {'invalid-argument-type'},
      );
      await _expectCodes(runtime.execute('old_name + 1').result, {
        'unresolved-reference',
      });
      await _expectRuntimeError(
        runtime.execute('old_name', skipTypeCheck: true).result,
        'NameError',
      );
    } finally {
      await runtime.dispose();
    }
  });
}

Future<MontyRuntime> _runtime(
  Monty pool, {
  bool checked = true,
  bool sandbox = false,
  String? format = 'json',
  List<String>? calls,
}) async {
  final runtime = await MontyRuntime.start(
    pool: pool,
    sandbox: sandbox,
    typeCheck: checked,
    typeCheckStubs: checked ? typecheckStubs : null,
    typeCheckFormat: checked ? format : null,
  );
  typecheckHostFunctions(calls ?? []).forEach(runtime.register);

  return runtime;
}

Future<void> _expectCodes(
  Future<MontyValue> future,
  Set<String> expected,
) async {
  final error = await _typingError(future);
  final diagnostics = jsonDecode(error.display())! as List<Object?>;
  final codes = {
    for (final item in diagnostics)
      (item! as Map<Object?, Object?>)['code']! as String,
  };
  expect(codes, expected);
}

Future<MontyTypingError> _typingError(Future<MontyValue> future) async {
  try {
    await future;
  } on MontyTypingError catch (error) {
    return error;
  }

  fail('Expected MontyTypingError');
}

Future<void> _expectRuntimeError(Future<MontyValue> future, String type) async {
  try {
    await future;
  } on MontyError catch (error) {
    expect(error, isNot(isA<MontyTypingError>()));
    expect(error.exception.excType, type);

    return;
  }

  fail('Expected MontyError');
}
