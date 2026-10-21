import 'dart:async';

import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyDict, MontyError, MontyString, MontyValue;

/// Builds a host function that runs loaded source in an isolated sub-session.
/// Input names must be non-keyword Python identifiers. Loader and input errors
/// surface in Python.
HostFunction buildRunScriptFunction(
  FutureOr<String> Function(String path) readFile,
) {
  return HostFunction(
    schema: const HostFunctionSchema(
      name: 'run_script',
      description:
          'Execute a script file and return its last-expression value. '
          'inputs are injected as Python variables before the script runs.',
      params: [
        HostParam(
          name: 'path',
          type: HostParamType.string,
          description: 'Path to the script file.',
        ),
        HostParam(
          name: 'inputs',
          type: HostParamType.map,
          isRequired: false,
          description:
              'Optional key/value pairs injected as Python variables '
              'before the script runs.',
        ),
      ],
    ),
    handler: (args, ctx) async {
      final path = (args['path']! as MontyString).value;
      final rawInputs = args['inputs'];
      final inputs = rawInputs is MontyDict ? _scriptInputs(rawInputs) : null;

      final subExecute = ctx.subExecute;
      if (subExecute == null) {
        throw StateError(
          'run_script: no subExecute wired into HostContext. '
          'Register the function on a real MontyRuntime, not a bare test ctx.',
        );
      }

      final String code;
      try {
        code = await readFile(path);
      } on Object catch (e) {
        throw Exception('run_script: could not read "$path": $e');
      }

      final MontyValue result;
      try {
        result = await subExecute(code, inputs: inputs);
      } on MontyError catch (e) {
        final msg = e.exception.message ?? 'unknown error';
        throw Exception('run_script("$path") failed: $msg');
      }

      return result;
    },
  );
}

/// Variable names are Python identifiers, never stringified dict keys.
Map<String, MontyValue> _scriptInputs(MontyDict inputs) {
  final result = <String, MontyValue>{};
  for (final (key, value) in inputs.pairs) {
    if (key is! MontyString ||
        !_variableName.hasMatch(key.value) ||
        _keywords.contains(key.value)) {
      throw ArgumentError('run_script inputs require string variable names');
    }
    result[key.value] = value;
  }

  return result;
}

final _variableName = RegExp(
  r'^[_\p{XID_Start}]\p{XID_Continue}*$',
  unicode: true,
);
const _keywords = {
  'False',
  'None',
  'True',
  'and',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'class',
  'continue',
  'def',
  'del',
  'elif',
  'else',
  'except',
  'finally',
  'for',
  'from',
  'global',
  'if',
  'import',
  'in',
  'is',
  'lambda',
  'nonlocal',
  'not',
  'or',
  'pass',
  'raise',
  'return',
  'try',
  'while',
  'with',
  'yield',
};
