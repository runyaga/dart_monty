import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// Minimal test plugin with configurable namespace and functions.
class _TestPlugin extends MontyPlugin {
  _TestPlugin({
    required this.namespace,
    this.systemPromptContext,
    List<HostFunction>? functions,
  }) : functions = functions ?? [];

  @override
  final String namespace;

  @override
  final String? systemPromptContext;

  @override
  final List<HostFunction> functions;
}

HostFunction _fn(String name) => HostFunction(
  schema: HostFunctionSchema(name: name, description: ''),
  handler: (args) async => null,
);

void main() {
  late PluginRegistry registry;

  setUp(() {
    registry = PluginRegistry();
  });

  group('PluginRegistry', () {
    test('empty registry has empty plugins list', () {
      expect(registry.plugins, isEmpty);
    });

    test('register adds plugin to plugins list', () {
      final plugin = _TestPlugin(
        namespace: 'alpha',
        systemPromptContext: 'Alpha operations.',
      );

      registry.register(plugin);

      expect(registry.plugins, hasLength(1));
      expect(registry.plugins.first.namespace, 'alpha');
      expect(registry.plugins.first.systemPromptContext, 'Alpha operations.');
    });

    test('multiple plugins register successfully', () {
      registry
        ..register(_TestPlugin(namespace: 'aaa', functions: [_fn('aaa_do')]))
        ..register(_TestPlugin(namespace: 'bbb', functions: [_fn('bbb_do')]));

      expect(registry.plugins, hasLength(2));
      expect(registry.plugins[0].namespace, 'aaa');
      expect(registry.plugins[1].namespace, 'bbb');
    });

    test('accepts plugins with disjoint namespaces and function names', () {
      final p1 = _TestPlugin(
        namespace: 'alpha',
        functions: [_fn('alpha_one'), _fn('alpha_two')],
      );
      final p2 = _TestPlugin(namespace: 'beta', functions: [_fn('beta_one')]);

      registry
        ..register(p1)
        ..register(p2);

      expect(registry.plugins, hasLength(2));
    });

    test('plugins list is unmodifiable', () {
      registry.register(_TestPlugin(namespace: 'ns'));

      expect(
        () => registry.plugins.add(_TestPlugin(namespace: 'hack')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    group('namespace validation', () {
      test('rejects empty namespace string', () {
        expect(
          () => registry.register(_TestPlugin(namespace: '')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('must not be empty'),
            ),
          ),
        );
      });

      test('rejects namespace with uppercase characters', () {
        expect(
          () => registry.register(_TestPlugin(namespace: 'MyPlugin')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('invalid characters'),
            ),
          ),
        );
      });

      test('rejects namespace with spaces', () {
        expect(
          () => registry.register(_TestPlugin(namespace: 'my plugin')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('invalid characters'),
            ),
          ),
        );
      });

      test('rejects namespace with special characters', () {
        expect(
          () => registry.register(_TestPlugin(namespace: 'my-plugin')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('invalid characters'),
            ),
          ),
        );
      });

      test('rejects namespace starting with digit', () {
        expect(
          () => registry.register(_TestPlugin(namespace: '1abc')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('invalid characters'),
            ),
          ),
        );
      });

      test('rejects namespace exceeding 32 characters', () {
        final long = 'a' * 33;

        expect(
          () => registry.register(_TestPlugin(namespace: long)),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('exceeds maximum length'),
            ),
          ),
        );
      });

      test('rejects reserved namespace "introspection"', () {
        expect(
          () => registry.register(_TestPlugin(namespace: 'introspection')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('reserved'),
            ),
          ),
        );
      });

      test('rejects reserved namespace "extra"', () {
        expect(
          () => registry.register(_TestPlugin(namespace: 'extra')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('reserved'),
            ),
          ),
        );
      });
    });

    group('function prefix enforcement', () {
      test('rejects function not prefixed with namespace', () {
        expect(
          () => registry.register(
            _TestPlugin(namespace: 'sqlite', functions: [_fn('query')]),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('query'), contains('sqlite_')),
            ),
          ),
        );
      });

      test('accepts function correctly prefixed with namespace', () {
        registry.register(
          _TestPlugin(namespace: 'sqlite', functions: [_fn('sqlite_query')]),
        );

        expect(registry.plugins, hasLength(1));
      });
    });

    group('collision detection', () {
      test('throws StateError on duplicate namespace', () {
        registry.register(_TestPlugin(namespace: 'df'));

        expect(
          () => registry.register(_TestPlugin(namespace: 'df')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('already registered'),
            ),
          ),
        );
      });

      test('throws StateError on function name collision across plugins', () {
        // alpha_s_thing satisfies both alpha_ and alpha_s_ prefixes,
        // so registering it under both namespaces causes a collision.
        registry.register(
          _TestPlugin(namespace: 'alpha', functions: [_fn('alpha_s_thing')]),
        );

        expect(
          () => registry.register(
            _TestPlugin(
              namespace: 'alpha_s',
              functions: [_fn('alpha_s_thing')],
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('alpha_s_thing'),
                contains('alpha_s'),
                contains('conflicts'),
              ),
            ),
          ),
        );
      });

      test('collision does not partially register the plugin', () {
        // alpha_s_one satisfies prefix alpha_ — register it under alpha.
        registry.register(
          _TestPlugin(namespace: 'alpha', functions: [_fn('alpha_s_one')]),
        );

        // alpha_s tries to register alpha_s_ok (valid, no collision) and
        // alpha_s_one (valid prefix, but collides). The whole plugin should
        // be rejected — no partial registration.
        expect(
          () => registry.register(
            _TestPlugin(
              namespace: 'alpha_s',
              functions: [_fn('alpha_s_ok'), _fn('alpha_s_one')],
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(registry.plugins, hasLength(1));
        expect(registry.plugins.first.namespace, 'alpha');
      });
    });

    group('attachTo', () {
      test(
        'registers all functions onto bridge and calls onRegister',
        () async {
          final registered = <String>[];
          final bridge = _MockBridge();

          final plugin = _LifecyclePlugin(
            namespace: 'lc',
            functions: [_fn('lc_do')],
            onRegisterCallback: () => registered.add('lc'),
          );
          registry.register(plugin);

          await registry.attachTo(bridge);

          // Plugin function + introspection builtins should be registered.
          expect(bridge.registeredNames, contains('lc_do'));
          expect(bridge.registeredNames, contains('list_functions'));
          expect(bridge.registeredNames, contains('help'));
          expect(registered, ['lc']);
        },
      );

      test('calls onRegister in registration order', () async {
        final order = <String>[];
        final bridge = _MockBridge();

        registry
          ..register(
            _LifecyclePlugin(
              namespace: 'first',
              functions: [_fn('first_a')],
              onRegisterCallback: () => order.add('first'),
            ),
          )
          ..register(
            _LifecyclePlugin(
              namespace: 'second',
              functions: [_fn('second_a')],
              onRegisterCallback: () => order.add('second'),
            ),
          );

        await registry.attachTo(bridge);

        expect(order, ['first', 'second']);
      });

      test('registers extraFunctions onto bridge', () async {
        final bridge = _MockBridge();
        registry.register(
          _TestPlugin(namespace: 'ns', functions: [_fn('ns_one')]),
        );

        await registry.attachTo(
          bridge,
          extraFunctions: [_fn('standalone_op')],
        );

        expect(bridge.registeredNames, contains('ns_one'));
        expect(bridge.registeredNames, contains('standalone_op'));
        expect(bridge.registeredNames, contains('list_functions'));
      });

      test('extraFunctions with null or empty list is a no-op', () async {
        final bridge = _MockBridge();
        registry.register(
          _TestPlugin(namespace: 'ns', functions: [_fn('ns_one')]),
        );

        await registry.attachTo(bridge, extraFunctions: []);

        expect(bridge.registeredNames, contains('ns_one'));
        expect(bridge.registeredNames, isNot(contains('standalone_op')));
      });

      test('attaches all plugins even if onRegister throws', () async {
        final bridge = _MockBridge();

        registry
          ..register(
            _LifecyclePlugin(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onRegisterCallback: () => throw Exception('aaa boom'),
            ),
          )
          ..register(
            _LifecyclePlugin(namespace: 'bbb', functions: [_fn('bbb_x')]),
          );

        await expectLater(
          registry.attachTo(bridge),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('1 plugin(s)'), contains('aaa')),
            ),
          ),
        );

        // Both plugins' functions were registered onto the bridge.
        expect(bridge.registeredNames, contains('aaa_x'));
        expect(bridge.registeredNames, contains('bbb_x'));
        expect(bridge.registeredNames, contains('list_functions'));
      });
    });

    group('disposeAll', () {
      test('calls onDispose in reverse registration order', () async {
        final order = <String>[];

        registry
          ..register(
            _LifecyclePlugin(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => order.add('aaa'),
            ),
          )
          ..register(
            _LifecyclePlugin(
              namespace: 'bbb',
              functions: [_fn('bbb_x')],
              onDisposeCallback: () => order.add('bbb'),
            ),
          );

        await registry.disposeAll();

        expect(order, ['bbb', 'aaa']);
      });

      test('is idempotent', () async {
        var count = 0;
        registry.register(
          _LifecyclePlugin(
            namespace: 'idem',
            functions: [_fn('idem_x')],
            onDisposeCallback: () => count++,
          ),
        );

        await registry.disposeAll();
        await registry.disposeAll();

        expect(count, 2); // Called twice — plugin must be idempotent.
      });

      test('disposes all plugins even if one throws', () async {
        final disposed = <String>[];

        registry
          ..register(
            _LifecyclePlugin(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => disposed.add('aaa'),
            ),
          )
          ..register(
            _LifecyclePlugin(
              namespace: 'bbb',
              functions: [_fn('bbb_x')],
              onDisposeCallback: () => throw Exception('bbb boom'),
            ),
          )
          ..register(
            _LifecyclePlugin(
              namespace: 'ccc',
              functions: [_fn('ccc_x')],
              onDisposeCallback: () => disposed.add('ccc'),
            ),
          );

        await expectLater(
          registry.disposeAll(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('1 plugin(s)'), contains('bbb')),
            ),
          ),
        );

        // All three were attempted (reverse order: ccc, bbb, aaa).
        expect(disposed, ['ccc', 'aaa']);
      });

      test('collects multiple dispose errors', () async {
        registry
          ..register(
            _LifecyclePlugin(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => throw Exception('aaa fail'),
            ),
          )
          ..register(
            _LifecyclePlugin(
              namespace: 'bbb',
              functions: [_fn('bbb_x')],
              onDisposeCallback: () => throw Exception('bbb fail'),
            ),
          );

        await expectLater(
          registry.disposeAll(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('2 plugin(s)'), contains('aaa'), contains('bbb')),
            ),
          ),
        );
      });
    });

    group('generateSystemPrompt', () {
      test('empty registry returns empty string', () {
        expect(registry.generateSystemPrompt(), isEmpty);
      });

      test('single plugin with functions produces expected markdown', () {
        registry.register(
          _TestPlugin(
            namespace: 'sqlite',
            systemPromptContext: 'SQLite operations.',
            functions: [
              HostFunction(
                schema: const HostFunctionSchema(
                  name: 'sqlite_query',
                  description: 'Run a query.',
                  params: [
                    HostParam(
                      name: 'sql',
                      type: HostParamType.string,
                      description: 'SQL string.',
                    ),
                  ],
                ),
                handler: (args) async => null,
              ),
            ],
          ),
        );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, contains('### sqlite'));
        expect(prompt, contains('SQLite operations.'));
        expect(prompt, contains('`sqlite_query(sql: string)`'));
        expect(prompt, contains('Run a query.'));
      });

      test('optional params show ? suffix', () {
        registry.register(
          _TestPlugin(
            namespace: 'demo',
            functions: [
              HostFunction(
                schema: const HostFunctionSchema(
                  name: 'demo_opt',
                  description: 'Has optional.',
                  params: [
                    HostParam(
                      name: 'limit',
                      type: HostParamType.integer,
                      isRequired: false,
                    ),
                  ],
                ),
                handler: (args) async => null,
              ),
            ],
          ),
        );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, contains('limit?: integer'));
      });

      test('systemPromptPrefix prepends before plugin sections', () {
        registry
          ..systemPromptPrefix = 'You are child 0. Workspace: /child_0.'
          ..register(
            _TestPlugin(
              namespace: 'alpha',
              systemPromptContext: 'Alpha operations.',
              functions: [_fn('alpha_one')],
            ),
          );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, startsWith('You are child 0.'));
        expect(
          prompt.indexOf('child 0'),
          lessThan(prompt.indexOf('### alpha')),
        );
      });

      test('null systemPromptPrefix produces no prefix', () {
        registry.register(
          _TestPlugin(
            namespace: 'ns',
            functions: [_fn('ns_one')],
          ),
        );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, startsWith('### ns'));
      });

      test('empty systemPromptPrefix produces no prefix', () {
        registry
          ..systemPromptPrefix = ''
          ..register(
            _TestPlugin(
              namespace: 'ns',
              functions: [_fn('ns_one')],
            ),
          );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, startsWith('### ns'));
      });

      test('systemPromptPrefix alone (no plugins) returns prefix', () {
        registry.systemPromptPrefix = 'You are the validator.';

        final prompt = registry.generateSystemPrompt();

        expect(prompt, contains('You are the validator.'));
      });

      test('multiple plugins produce sections in registration order', () {
        registry
          ..register(
            _TestPlugin(
              namespace: 'alpha',
              systemPromptContext: 'Alpha stuff.',
              functions: [_fn('alpha_one')],
            ),
          )
          ..register(
            _TestPlugin(
              namespace: 'beta',
              systemPromptContext: 'Beta stuff.',
              functions: [_fn('beta_one')],
            ),
          );

        final prompt = registry.generateSystemPrompt();
        final alphaIdx = prompt.indexOf('### alpha');
        final betaIdx = prompt.indexOf('### beta');

        expect(alphaIdx, lessThan(betaIdx));
      });
    });
  });
}

/// Plugin with configurable lifecycle callbacks for testing.
class _LifecyclePlugin extends MontyPlugin {
  _LifecyclePlugin({
    required this.namespace,
    required this.functions,
    this.onRegisterCallback,
    this.onDisposeCallback,
  });

  @override
  final String namespace;

  @override
  final String? systemPromptContext = null;

  @override
  final List<HostFunction> functions;

  final void Function()? onRegisterCallback;
  final void Function()? onDisposeCallback;

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    onRegisterCallback?.call();
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    onDisposeCallback?.call();
  }
}

/// Minimal bridge mock that tracks registered function names.
class _MockBridge implements MontyBridge {
  final registeredNames = <String>[];

  @override
  BridgeLogger get logger => const NullBridgeLogger();

  @override
  List<HostFunctionSchema> get schemas => [];

  @override
  void use(BridgeMiddleware middleware) {}

  @override
  void register(HostFunction function) {
    registeredNames.add(function.schema.name);
  }

  @override
  void unregister(String name) {}

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
