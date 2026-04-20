import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/args.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/render_hint.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dinja/dinja.dart';

/// Default maximum input size for template strings (512 KB).
const int defaultMaxTemplateInputSize = 512 * 1024;

/// Plugin that provides Jinja2 template rendering to Python scripts.
///
/// Uses [dinja](https://pub.dev/packages/dinja), a minimal Jinja2
/// implementation for Dart. Supports `{{ variables }}`,
/// `{% for item in items %}` loops, and `{% if condition %}` conditionals.
///
/// All functions are prefixed with `tmpl_`.
class JinjaTemplateExtension extends MontyExtension {
  /// Creates a [JinjaTemplateExtension].
  ///
  /// [maxInputSize] controls the maximum allowed character count for
  /// template strings. Defaults to 512 KB.
  JinjaTemplateExtension({int? maxInputSize})
    : _maxInputSize = maxInputSize ?? defaultMaxTemplateInputSize;

  final int _maxInputSize;

  @override
  String get namespace => 'tmpl';

  @override
  String? get systemPromptContext =>
      'Render Jinja2 templates. Use tmpl_render to fill a template string '
      'with values from a context dict. Supports {{ variable }}, '
      '{% for item in items %}...{% endfor %} loops, '
      '{% if condition %}...{% endif %} conditionals, and filters.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'tmpl_render',
        description:
            'Render a Jinja2 template string with the given context dict. '
            'Supports {{ variable }}, {% for %}, {% if %}, and filters.',
        params: [
          HostParam(
            name: 'template',
            type: HostParamType.string,
            description: 'Jinja2 template string.',
            renderAs: ParamRenderHint.jinja,
          ),
          HostParam(
            name: 'context',
            type: HostParamType.map,
            description: 'Context dict for template variables.',
          ),
        ],
      ),
      handler: _handleRender,
    ),
  ];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      JinjaTemplateExtension(maxInputSize: _maxInputSize);

  Future<Object?> _handleRender(Map<String, Object?> args, HostContext ctx) {
    final templateStr = args.str('template');
    final context = args.mapArg('context');
    _guardInputSize(templateStr);

    try {
      final template = Template(templateStr);
      final result = template.render(context);
      logger.debug(
        'tmpl_render ok',
        attributes: {'templateLength': templateStr.length},
      );

      return Future.value(result);
    } on Exception catch (e) {
      throw FormatException('Template error: $e');
    }
  }

  void _guardInputSize(String template) {
    if (template.length > _maxInputSize) {
      throw FormatException(
        'Template exceeds $_maxInputSize character limit '
        '(got ${template.length})',
      );
    }
  }
}
