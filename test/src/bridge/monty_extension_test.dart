import 'package:dart_monty/dart_monty.dart';
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
        handler: (args, _) async => const MontyNone(),
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

    test("SandboxExtension's own policy is exclude", () {
      expect(SandboxExtension().childPolicy, ChildPolicy.exclude);
    });

    test('supportedBackends defaults to both kinds', () {
      expect(
        _TestExtension(namespace: 'ns', functions: []).supportedBackends,
        {MontyBackendKind.ffi, MontyBackendKind.wasm},
      );
    });

    test('logger is BridgeLogger.silent before attach', () {
      final plugin = _TestExtension(namespace: 'ns', functions: []);
      expect(plugin.logger, same(BridgeLogger.silent));
    });
  });
}

/// Minimal [MontyBridge] for lifecycle tests — not exercised.
class _NoOpBridge implements MontyBridge {
  @override
  BridgeLogger get logger => BridgeLogger.silent;

  @override
  List<HostFunctionSchema> get schemas => [];

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory => {};

  @override
  void register(HostFunction function, {String? category}) {}

  @override
  void unregister(String name) {}

  @override
  void registerOs(OsHandler handler) {}

  @override
  Stream<BridgeEvent> execute(String code) => const Stream.empty();

  @override
  Future<MontyValue> invokeHostFunction(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  }) => throw UnimplementedError();

  @override
  void dispose() {}
}
