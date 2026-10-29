import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyHostFunction, MontyPath;

/// Deterministic tools shared by the parent and explicitly admitted children.
Map<String, Object?> demoTools({void Function()? onCall}) => {
      'tools': ExternalModule({
        'add': MontyHostFunction(
          'add',
          (args, _) {
            onCall?.call();
            return MontyInt(
              (args[0] as MontyInt).value + (args[1] as MontyInt).value,
            );
          },
        ),
      }),
    };

/// Starts a parent workspace; child file and module ownership is explicit.
Future<MontyRuntime> startShowcase(
  Monty pool, {
  bool grant = true,
  void Function()? onToolCall,
}) async {
  final files = OSAccess();
  await files.call('Path.mkdir', [MontyPath('/work')], {});
  final runtime = await MontyRuntime.start(
    pool: pool,
    os: files.call,
    externalModules: demoTools(onCall: onToolCall),
    extensions: [
      SandboxExtension(
        childExternalModules: grant ? demoTools(onCall: onToolCall) : null,
      ),
    ],
  );
  try {
    await runtime.execute("import os\nos.chdir('/work')").result;
    return runtime;
  } on Object {
    await runtime.dispose();
    rethrow;
  }
}
