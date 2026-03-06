import 'package:dart_monty_bridge/dart_monty_bridge.dart';
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
    });

    group('function prefix enforcement', () {
      test('rejects function not prefixed with namespace', () {
        expect(
          () => registry.register(
            _TestPlugin(
              namespace: 'sqlite',
              functions: [_fn('query')],
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('query'),
                contains('sqlite_'),
              ),
            ),
          ),
        );
      });

      test('accepts function correctly prefixed with namespace', () {
        registry.register(
          _TestPlugin(
            namespace: 'sqlite',
            functions: [_fn('sqlite_query')],
          ),
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
          _TestPlugin(
            namespace: 'alpha',
            functions: [_fn('alpha_s_thing')],
          ),
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
          _TestPlugin(
            namespace: 'alpha',
            functions: [_fn('alpha_s_one')],
          ),
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
  });
}
