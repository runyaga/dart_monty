import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Minimal concrete implementation for testing the abstract class.
class _TestExtension extends MontyExtension {
  _TestExtension({
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
  group('MontyExtension', () {
    test('exposes namespace, systemPromptContext, and functions', () {
      final fn = HostFunction(
        schema: const HostFunctionSchema(
          name: 'do_thing',
          description: 'Does a thing.',
        ),
        handler: (args, _) async => null,
      );

      final plugin = _TestExtension(
        namespace: 'my_ns',
        systemPromptContext: 'Does cool things.',
        functions: [fn],
      );

      expect(plugin.namespace, 'my_ns');
      expect(plugin.systemPromptContext, 'Does cool things.');
      expect(plugin.functions, hasLength(1));
      expect(plugin.functions.first.schema.name, 'do_thing');
    });

    test('onAttach default implementation is a no-op', () async {
      final plugin = _TestExtension(
        namespace: 'ns',
        systemPromptContext: '',
        functions: [],
      );

      // Should complete without error.
      await plugin.onAttach(_NoOpBridge());
    });

    test('systemPromptContext defaults to null', () {
      final plugin = _TestExtension(namespace: 'ns', functions: []);

      expect(plugin.systemPromptContext, isNull);
    });

    test('childPolicy defaults to exclude', () {
      final plugin = _TestExtension(namespace: 'ns', functions: []);

      expect(plugin.childPolicy, ChildPolicy.exclude);
    });

    test('createChildInstance throws when not overridden', () {
      final plugin = _TestExtension(namespace: 'ns', functions: []);
      const context = ChildSpawnContext(
        childId: 42,
        workingDirectory: '/tmp/child_42',
      );

      expect(
        () => plugin.createChildInstance(context),
        throwsUnsupportedError,
      );
    });

    test('onDispose default implementation is a no-op', () async {
      final plugin = _TestExtension(
        namespace: 'ns',
        systemPromptContext: '',
        functions: [],
      );

      // Should complete without error.
      await plugin.onDispose();
    });

    test('osContribution defaults to null', () {
      final plugin = _TestExtension(namespace: 'ns', functions: []);
      expect(plugin.osContribution, isNull);
    });

    test(
      'accessing coordinator before attachTo throws LateInitializationError',
      () {
        final plugin = _TestExtension(namespace: 'ns', functions: []);
        // LateInitializationError is a subtype of Error.
        expect(() => plugin.coordinator, throwsA(isA<Error>()));
      },
    );
  });
}

/// Minimal [MontyBridge] for lifecycle tests — not exercised.
class _NoOpBridge implements MontyBridge {
  @override
  BridgeLogger get logger => const NullBridgeLogger();

  @override
  List<HostFunctionSchema> get schemas => [];

  @override
  List<HostFunctionSchema> get llmSchemas => [];

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory => {};

  @override
  void register(HostFunction function, {String? category}) {}

  @override
  void unregister(String name) {}

  @override
  void registerOs(OsCallHandler handler) {}

  @override
  Stream<BridgeEvent> execute(String code) => const Stream.empty();

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args,
  ) => throw UnimplementedError();

  @override
  void dispose() {}
}
