import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dinja/dinja.dart';
import 'package:struct_log/struct_log.dart';

/// Maximum input size for template strings (512 KB).
///
/// Guards against template expansion bombs that could block the main thread.
const int _maxTemplateInputBytes = 512 * 1024;

/// Plugin that provides Jinja2 template rendering to Python scripts.
///
/// Uses [dinja](https://pub.dev/packages/dinja), a minimal Jinja2
/// implementation for Dart. Supports `{{ variables }}`,
/// `{% for item in items %}` loops, and `{% if condition %}` conditionals.
///
/// All functions are prefixed with `tmpl_`.
class TemplatePlugin extends MontyPlugin {
  /// Creates a [TemplatePlugin].
  TemplatePlugin({Logger? logger})
    : log = logger ?? LogManager.instance.getLogger('TemplatePlugin');

  /// Logger for this plugin instance.
  final Logger log;

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
  MontyPlugin? createChildInstance() => TemplatePlugin(
    logger: LogManager.instance.getLogger('TemplatePlugin.child'),
  );

  Future<Object?> _handleRender(Map<String, Object?> args) async {
    final templateStr = args['template']! as String;
    final context = args['context']! as Map<String, Object?>;
    _guardInputSize(templateStr);

    try {
      final template = Template(templateStr);
      final result = template.render(context);
      log.debug(
        'tmpl_render ok',
        attributes: {'templateLength': templateStr.length},
      );
      return result;
    } on Exception catch (e) {
      throw FormatException('Template error: $e');
    }
  }

  void _guardInputSize(String template) {
    if (template.length > _maxTemplateInputBytes) {
      throw FormatException(
        'Template exceeds ${_maxTemplateInputBytes ~/ 1024} KB limit '
        '(got ${template.length} bytes)',
      );
    }
  }
}
