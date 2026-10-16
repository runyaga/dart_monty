import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/args.dart';

/// A second extension for integration tests that combine extensions.
///
/// `tmpl_render(template, context)` replaces each `{{ key }}` in `template`
/// with `context[key]`. Nothing else: no loops, conditionals or filters.
/// Uses [ChildPolicy.clone], so children spawned by `SandboxExtension` get
/// their own instance.
class TemplateStubExtension extends MontyExtension {
  static final _placeholder = RegExp(r'\{\{\s*(\w+)\s*\}\}');

  @override
  String get namespace => 'tmpl';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'tmpl_render',
        description: 'Replace each {{ key }} in template with context[key].',
        params: [
          HostParam(name: 'template', type: HostParamType.string),
          HostParam(name: 'context', type: HostParamType.map),
        ],
      ),
      handler: _render,
    ),
  ];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      TemplateStubExtension();

  Future<Object?> _render(Map<String, Object?> args, HostContext ctx) async {
    final template = args.str('template');
    final context = args.mapArg('context');

    return template.replaceAllMapped(
      _placeholder,
      (m) => '${context[m[1]]}',
    );
  }
}
