import 'dart:async';

import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyDict, MontyError, MontyString, MontyValue;

/// Builds a `run_script` [HostFunction] that Python code can call to execute
/// another script file and receive its last-expression value.
///
/// [readFile] is invoked with the requested path and must return the script's
/// source code. Wire it to a VFS, `dart:io` file read, or any other source:
///
/// ```dart
/// runtime.register(buildRunScriptFunction(
///   (path) => vfs.readFile(path),
/// ));
/// ```
///
/// From Python:
/// ```python
/// greeting = run_script('greet.py', inputs={'name': 'Alice'})
/// ```
///
/// The sub-script runs through `ctx.subExecute`, on a second session checked
/// out of the runtime's pool while the caller stays suspended, so it shares
/// no state and no registered host functions with the caller. Its
/// last-expression [MontyValue] is returned to Python as it is.
///
/// Fails with [StateError] when the context has no `subExecute` (a bare
/// test context), with `run_script: could not read "<path>": <error>` when
/// [readFile] throws, and with `run_script("<path>") failed: <message>`,
/// the [MontyError]'s `exception.message`, when the sub-script raises.
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
