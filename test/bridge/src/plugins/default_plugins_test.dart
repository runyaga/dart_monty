import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('defaultPlugins', () {
    test('returns Jinja, MessageBus, and EventLoop plugins', () {
      final plugins = defaultPlugins();

      expect(plugins, hasLength(3));
      expect(plugins[0], isA<JinjaTemplatePlugin>());
      expect(plugins[1], isA<MessageBusPlugin>());
      expect(plugins[2], isA<EventLoopPlugin>());
    });

    test('returns a fresh list on each call', () {
      final a = defaultPlugins();
      final b = defaultPlugins();

      expect(identical(a, b), isFalse);
      expect(identical(a[0], b[0]), isFalse);
    });

    test('does not include SandboxPlugin (needs platformFactory)', () {
      final plugins = defaultPlugins();
      expect(plugins.any((p) => p is SandboxPlugin), isFalse);
    });
  });
}
