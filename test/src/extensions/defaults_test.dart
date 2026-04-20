import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('defaultExtensions', () {
    test('returns Jinja, MessageBus, and EventLoop extensions', () {
      final extensions = defaultExtensions();

      expect(extensions, hasLength(3));
      expect(extensions[0], isA<JinjaTemplateExtension>());
      expect(extensions[1], isA<MessageBusExtension>());
      expect(extensions[2], isA<EventLoopExtension>());
    });

    test('returns a fresh list on each call', () {
      final a = defaultExtensions();
      final b = defaultExtensions();

      expect(identical(a, b), isFalse);
      expect(identical(a[0], b[0]), isFalse);
    });

    test('does not include SandboxExtension (needs platformFactory)', () {
      final extensions = defaultExtensions();
      expect(extensions.any((p) => p is SandboxExtension), isFalse);
    });
  });
}
