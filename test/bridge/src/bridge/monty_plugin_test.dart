import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

/// Minimal concrete implementation for testing the abstract class.
class _TestPlugin extends MontyPlugin {
  _TestPlugin({
    required this.namespace,
    required this.functions,
    this.systemPromptContext,
  });

  @override
  final String namespace;

  @override
  final String? systemPromptContext;

  @override
  final List<HostFunction> functions;
}

void main() {
  group('MontyPlugin', () {
    test('exposes namespace, systemPromptContext, and functions', () {
      final fn = HostFunction(
        schema: const HostFunctionSchema(
          name: 'do_thing',
          description: 'Does a thing.',
        ),
        handler: (args) async => null,
      );

      final plugin = _TestPlugin(
        namespace: 'my_ns',
        systemPromptContext: 'Does cool things.',
        functions: [fn],
      );

      expect(plugin.namespace, 'my_ns');
      expect(plugin.systemPromptContext, 'Does cool things.');
      expect(plugin.functions, hasLength(1));
      expect(plugin.functions.first.schema.name, 'do_thing');
    });

    test('onRegister default implementation is a no-op', () async {
      final plugin = _TestPlugin(
        namespace: 'ns',
        systemPromptContext: '',
        functions: [],
      );

      // Should complete without error.
      await plugin.onRegister(_NoOpBridge());
    });

    test('systemPromptContext defaults to null', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);

      expect(plugin.systemPromptContext, isNull);
    });

    test('createChildInstance defaults to null', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);

      expect(plugin.createChildInstance(), isNull);
    });

    test('createChildInstance accepts optional context', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      const context = ChildSpawnContext(
        childId: 42,
        workingDirectory: '/tmp/child_42',
      );

      expect(plugin.createChildInstance(context: context), isNull);
    });

    test('onDispose default implementation is a no-op', () async {
      final plugin = _TestPlugin(
        namespace: 'ns',
        systemPromptContext: '',
        functions: [],
      );

      // Should complete without error.
      await plugin.onDispose();
    });
  });
}

/// Minimal [MontyBridge] for lifecycle tests — not exercised.
class _NoOpBridge implements MontyBridge {
  @override
  BridgeLogger get logger => const NullBridgeLogger();

  @override
  List<HostFunctionSchema> get schemas => [];

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory => {};

  @override
  void use(BridgeMiddleware middleware) {}

  @override
  void register(HostFunction function, {String? category}) {}

  @override
  void unregister(String name) {}

  @override
  void registerOs(OsProvider provider) {}

  @override
  Stream<BridgeEvent> execute(String code) => const Stream.empty();

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    CallRole role = const ToolCall(),
  }) => throw UnimplementedError();

  @override
  void dispose() {}
}
