/// Python Ladder JSONL Runner — standalone script for parity comparison.
///
/// Runs all fixtures through MontyFfi and outputs one JSONL line per fixture:
///   {"id":1,"ok":true,"value":4}
///
/// Usage:
/// ```bash
/// cd packages/dart_monty_ffi
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test/integration/python_ladder_runner.dart
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

Future<void> main() async {
  final bindings = NativeBindingsFfi();
  final fixtureDir = Directory('../../test/fixtures/python_ladder');
  final tierFiles = fixtureDir
      .listSync()
      .whereType<File>()
      .where(
        (f) => f.path.endsWith('.json'),
      )
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in tierFiles) {
    final fixtures = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

    for (final fixture in fixtures) {
      final result = await _runFixture(bindings, fixture);
      stdout.writeln(jsonEncode(result));
    }
  }
}

Future<Map<String, dynamic>> _runFixture(
  NativeBindingsFfi bindings,
  Map<String, dynamic> fixture,
) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final expectError = fixture['expectError'] as bool? ?? false;
  final xfail = fixture['xfail'] as String?;
  final monty = MontyFfi(bindings: bindings);

  Map<String, dynamic> result;
  try {
    if (fixture['externalFunctions'] != null) {
      result = await _runIterative(monty, fixture);
    } else if (expectError) {
      result = await _runExpectError(monty, id, code);
    } else {
      result = await _runSimple(monty, id, code);
    }
  } on Object catch (e) {
    result = {'id': id, 'ok': false, 'error': '$e'};
  } finally {
    await monty.dispose();
  }

  if (xfail != null) {
    return result['ok'] == true
        ? {'id': id, 'ok': true, 'xpass': true}
        : {'id': id, 'ok': true, 'xfail': true};
  }

  return result;
}

Future<Map<String, dynamic>> _runSimple(
  MontyFfi monty,
  int id,
  String code,
) async {
  final result = await monty.run(code);

  return {'id': id, 'ok': true, 'value': result.value};
}

Future<Map<String, dynamic>> _runExpectError(
  MontyFfi monty,
  int id,
  String code,
) async {
  try {
    await monty.run(code);

    return {'id': id, 'ok': false, 'error': 'Expected error but succeeded'};
  } on MontyException catch (e) {
    return {'id': id, 'ok': true, 'error': e.message};
  }
}

Future<Map<String, dynamic>> _runIterative(
  MontyFfi monty,
  Map<String, dynamic> fixture,
) async {
  final id = fixture['id'] as int;
  final code = fixture['code'] as String;
  final extFns = (fixture['externalFunctions'] as List).cast<String>();
  final resumeValues = (fixture['resumeValues'] as List?)?.cast<Object>();
  final resumeErrors = (fixture['resumeErrors'] as List?)?.cast<String>();

  var progress = await monty.start(code, externalFunctions: extFns);

  if (resumeErrors != null) {
    for (final errorMsg in resumeErrors) {
      if (progress is! MontyPending) {
        return {'id': id, 'ok': false, 'error': 'Expected pending state'};
      }
      progress = await monty.resumeWithError(errorMsg);
    }
  } else if (resumeValues != null) {
    for (final value in resumeValues) {
      if (progress is! MontyPending) {
        return {'id': id, 'ok': false, 'error': 'Expected pending state'};
      }
      progress = await monty.resume(value);
    }
  }

  if (progress is! MontyComplete) {
    return {'id': id, 'ok': false, 'error': 'Expected complete state'};
  }

  return {'id': id, 'ok': true, 'value': progress.result.value};
}
