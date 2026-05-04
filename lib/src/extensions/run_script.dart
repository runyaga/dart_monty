import 'dart:async';

import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';

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
/// The sub-script runs on the same runtime, so it shares registered host
/// functions. Its last expression becomes the return value — exactly what
/// `MontyResult.value.dartValue` would return.
///
/// Throws a Python-visible exception if [readFile] fails or the sub-script
/// raises an error.
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
      final path = args['path']! as String;
      final rawInputs = args['inputs'];
      final inputs = rawInputs is Map
          ? rawInputs.map((k, v) => MapEntry(k.toString(), v as Object?))
          : null;

      final runtime = ctx.runtime;
      if (runtime == null) {
        throw StateError('run_script: no runtime available in this context');
      }

      final String code;
      try {
        code = await readFile(path);
      } on Object catch (e) {
        throw Exception('run_script: could not read "$path": $e');
      }

      final result = await runtime.execute(code, inputs: inputs).result;
      if (result.isError) {
        final msg = result.error?.message ?? 'unknown error';
        throw Exception('run_script("$path") failed: $msg');
      }

      return result.value.dartValue;
    },
  );
}
