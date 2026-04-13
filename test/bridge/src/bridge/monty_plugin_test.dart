import 'package:dart_monty/dart_monty_bridge.dart';
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

    test('hasExecuteHooks defaults to false', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      expect(plugin.hasExecuteHooks, isFalse);
    });

    test('hasStreamWrapper defaults to false', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      expect(plugin.hasStreamWrapper, isFalse);
    });

    test('osContribution defaults to null', () {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      expect(plugin.osContribution, isNull);
    });

    test('onExecuteStart default implementation is a no-op', () async {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      // Should complete without error.
      await plugin.onExecuteStart('x = 1');
    });

    test('onExecuteEnd default implementation is a no-op', () async {
      final plugin = _TestPlugin(namespace: 'ns', functions: []);
      const event = BridgeRunFinished(threadId: 't', runId: 'r');
      // Should complete without error for both outcome types.
      await plugin.onExecuteEnd(const ExecuteSuccess(event));
      await plugin.onExecuteEnd(
        const ExecuteFailure(BridgeRunError(message: 'err')),
      );
    });

    test(
      'accessing registry before attachTo throws LateInitializationError',
      () {
        final plugin = _TestPlugin(namespace: 'ns', functions: []);
        // LateInitializationError is a subtype of Error.
        expect(() => plugin.registry, throwsA(isA<Error>()));
      },
    );

    test('ExecuteSuccess carries the BridgeRunFinished event', () {
      const event = BridgeRunFinished(threadId: 'tid', runId: 'rid', value: 42);
      const outcome = ExecuteSuccess(event);
      expect(outcome.event, same(event));
      expect(outcome.event.value, 42);
    });

    test('ExecuteFailure carries the BridgeRunError event', () {
      const event = BridgeRunError(message: 'boom');
      const outcome = ExecuteFailure(event);
      expect(outcome.event, same(event));
      expect(outcome.event.message, 'boom');
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
