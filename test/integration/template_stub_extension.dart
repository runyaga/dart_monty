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

  Future<MontyValue> _render(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) {
    final template = args.str('template');
    final context = args['context']!.dartValue! as Map<Object?, Object?>;

    return Future.value(
      MontyString(
        template.replaceAllMapped(
          _placeholder,
          (m) => '${context[m[1]]}',
        ),
      ),
    );
  }
}
