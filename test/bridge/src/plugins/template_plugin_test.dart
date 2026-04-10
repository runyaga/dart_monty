import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  late DinjaTemplatePlugin plugin;

  setUp(() {
    plugin = DinjaTemplatePlugin();
  });

  HostFunctionHandler findHandler(String name) {
    return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
  }

  group('metadata', () {
    test('namespace is tmpl', () {
      expect(plugin.namespace, 'tmpl');
    });

    test('provides 1 host function', () {
      expect(plugin.functions, hasLength(1));
    });

    test('systemPromptContext is non-null', () {
      expect(plugin.systemPromptContext, isNotNull);
    });

    test('createChildInstance returns new DinjaTemplatePlugin', () {
      final child = plugin.createChildInstance();
      expect(child, isA<DinjaTemplatePlugin>());
      expect(child, isNot(same(plugin)));
    });
  });

  group('tmpl_render', () {
    test('renders simple variable substitution', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': 'Hello {{ name }}!',
        'context': {'name': 'World'},
      });
      expect(result, 'Hello World!');
    });

    test('renders for loop', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': '{% for item in items %}{{ item }} {% endfor %}',
        'context': {
          'items': ['a', 'b', 'c'],
        },
      });
      expect(result, contains('a'));
      expect(result, contains('b'));
      expect(result, contains('c'));
    });

    test('renders if conditional true', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': '{% if passed %}PASS{% endif %}',
        'context': {'passed': true},
      });
      expect(result, 'PASS');
    });

    test('renders if conditional false', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': '{% if passed %}PASS{% else %}FAIL{% endif %}',
        'context': {'passed': false},
      });
      expect(result, 'FAIL');
    });

    test('renders nested context', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': '{{ epoch.id }}: {{ epoch.verdict }}',
        'context': {
          'epoch': {'id': 'E106', 'verdict': 'FAIL'},
        },
      });
      expect(result, 'E106: FAIL');
    });

    test('renders empty template', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template': '',
        'context': <String, Object?>{},
      });
      expect(result, '');
    });

    test('handles missing variable gracefully', () async {
      final handler = findHandler('tmpl_render');
      // dinja should either render empty or preserve the tag
      final result = await handler({
        'template': 'value={{ missing }}',
        'context': <String, Object?>{},
      });
      expect(result, isA<String>());
    });

    test('throws FormatException for oversized input', () async {
      final handler = findHandler('tmpl_render');
      final huge = 'x' * (512 * 1024 + 1);
      expect(
        () => handler({
          'template': huge,
          'context': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });

    test('respects custom maxInputSize', () async {
      final small = DinjaTemplatePlugin(maxInputSize: 10);
      final handler = small.functions.firstWhere(
        (f) => f.schema.name == 'tmpl_render',
      );
      expect(
        () => handler.handler({
          'template': 'x' * 11,
          'context': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });

    test('renders loop over list of maps', () async {
      final handler = findHandler('tmpl_render');
      final result = await handler({
        'template':
            '{% for e in epochs %}{{ e.id }}:{{ e.score }} {% endfor %}',
        'context': {
          'epochs': [
            {'id': 'E106', 'score': 42},
            {'id': 'E107', 'score': 88},
          ],
        },
      });
      expect(result, contains('E106:42'));
      expect(result, contains('E107:88'));
    });
  });
}
