import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart' show ReadonlySignal;
import 'package:test/test.dart';

/// Minimal test plugin with configurable namespace and functions.
class _TestExtension extends MontyExtension {
  _TestExtension({
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
  handler: (args, _) async => null,
);

void main() {
  late ExtensionCoordinator registry;

  setUp(() {
    registry = ExtensionCoordinator();
  });

  group('ExtensionCoordinator', () {
    test('empty registry has empty plugins list', () {
      expect(registry.extensions, isEmpty);
    });

    test('register adds plugin to plugins list', () {
      final plugin = _TestExtension(
        namespace: 'alpha',
        systemPromptContext: 'Alpha operations.',
      );

      registry.register(plugin);

      expect(registry.extensions, hasLength(1));
      expect(registry.extensions.first.namespace, 'alpha');
      expect(
        registry.extensions.first.systemPromptContext,
        'Alpha operations.',
      );
    });

    test('multiple plugins register successfully', () {
      registry
        ..register(_TestExtension(namespace: 'aaa', functions: [_fn('aaa_do')]))
        ..register(
          _TestExtension(namespace: 'bbb', functions: [_fn('bbb_do')]),
        );

      expect(registry.extensions, hasLength(2));
      expect(registry.extensions[0].namespace, 'aaa');
      expect(registry.extensions[1].namespace, 'bbb');
    });

    test('accepts plugins with disjoint namespaces and function names', () {
      final p1 = _TestExtension(
        namespace: 'alpha',
        functions: [_fn('alpha_one'), _fn('alpha_two')],
      );
      final p2 = _TestExtension(
        namespace: 'beta',
        functions: [_fn('beta_one')],
      );

      registry
        ..register(p1)
        ..register(p2);

      expect(registry.extensions, hasLength(2));
    });

    test('plugins list is unmodifiable', () {
      registry.register(_TestExtension(namespace: 'ns'));

      expect(
        () => registry.extensions.add(_TestExtension(namespace: 'hack')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    group('namespace validation', () {
      test('rejects empty namespace string', () {
        expect(
          () => registry.register(_TestExtension(namespace: '')),
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
          () => registry.register(_TestExtension(namespace: 'MyPlugin')),
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
          () => registry.register(_TestExtension(namespace: 'my plugin')),
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
          () => registry.register(_TestExtension(namespace: 'my-plugin')),
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
          () => registry.register(_TestExtension(namespace: '1abc')),
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
          () => registry.register(_TestExtension(namespace: long)),
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
          () => registry.register(_TestExtension(namespace: 'introspection')),
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
          () => registry.register(_TestExtension(namespace: 'extra')),
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
            _TestExtension(namespace: 'sqlite', functions: [_fn('query')]),
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
          _TestExtension(namespace: 'sqlite', functions: [_fn('sqlite_query')]),
        );

        expect(registry.extensions, hasLength(1));
      });
    });

    group('collision detection', () {
      test('throws StateError on duplicate namespace', () {
        registry.register(_TestExtension(namespace: 'df'));

        expect(
          () => registry.register(_TestExtension(namespace: 'df')),
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
          _TestExtension(namespace: 'alpha', functions: [_fn('alpha_s_thing')]),
        );

        expect(
          () => registry.register(
            _TestExtension(
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
          _TestExtension(namespace: 'alpha', functions: [_fn('alpha_s_one')]),
        );

        // alpha_s tries to register alpha_s_ok (valid, no collision) and
        // alpha_s_one (valid prefix, but collides). The whole plugin should
        // be rejected — no partial registration.
        expect(
          () => registry.register(
            _TestExtension(
              namespace: 'alpha_s',
              functions: [_fn('alpha_s_ok'), _fn('alpha_s_one')],
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(registry.extensions, hasLength(1));
        expect(registry.extensions.first.namespace, 'alpha');
      });
    });

    group('register after attachTo', () {
      test('throws StateError', () async {
        final bridge = _MockBridge();
        registry.register(_TestExtension(namespace: 'df'));
        await registry.attachTo(bridge);

        expect(
          () => registry.register(_TestExtension(namespace: 'chart')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('chart'), contains('attachTo')),
            ),
          ),
        );
      });
    });

    group('attachTo', () {
      test(
        'registers all functions onto bridge and calls onAttach',
        () async {
          final registered = <String>[];
          final bridge = _MockBridge();

          final plugin = _LifecycleExtension(
            namespace: 'lc',
            functions: [_fn('lc_do')],
            onAttachCallback: () => registered.add('lc'),
          );
          registry.register(plugin);

          await registry.attachTo(bridge);

          // Plugin function + introspection builtin should be registered.
          expect(bridge.registeredNames, contains('lc_do'));
          expect(bridge.registeredNames, contains('help'));
          expect(registered, ['lc']);
        },
      );

      test('calls onAttach in registration order', () async {
        final order = <String>[];
        final bridge = _MockBridge();

        registry
          ..register(
            _LifecycleExtension(
              namespace: 'first',
              functions: [_fn('first_a')],
              onAttachCallback: () => order.add('first'),
            ),
          )
          ..register(
            _LifecycleExtension(
              namespace: 'second',
              functions: [_fn('second_a')],
              onAttachCallback: () => order.add('second'),
            ),
          );

        await registry.attachTo(bridge);

        expect(order, ['first', 'second']);
      });

      test('higher-priority plugin attaches before lower-priority', () async {
        final order = <String>[];
        final bridge = _MockBridge();

        // Register low-priority first, high-priority second —
        // attachment order must still be [high, low].
        registry
          ..register(
            _LifecycleExtension(
              namespace: 'low',
              functions: [_fn('low_a')],
              onAttachCallback: () => order.add('low'),
            ),
          )
          ..register(
            _LifecycleExtension(
              namespace: 'high',
              functions: [_fn('high_a')],
              onAttachCallback: () => order.add('high'),
              priority: 10,
            ),
          );

        await registry.attachTo(bridge);

        expect(order, ['high', 'low']);
      });

      test(
        'equal-priority plugins preserve registration order (stable sort)',
        () async {
          final order = <String>[];
          final bridge = _MockBridge();

          for (final ns in ['alpha', 'beta', 'gamma']) {
            registry.register(
              _LifecycleExtension(
                namespace: ns,
                functions: [_fn('${ns}_a')],
                onAttachCallback: () => order.add(ns),
                priority: 5,
              ),
            );
          }

          await registry.attachTo(bridge);

          expect(order, ['alpha', 'beta', 'gamma']);
        },
      );

      test(
        'higher-priority plugin disposes last (reverse of attach order)',
        () async {
          final disposeOrder = <String>[];
          final bridge = _MockBridge();

          registry
            ..register(
              _LifecycleExtension(
                namespace: 'low',
                functions: [_fn('low_b')],
                onDisposeCallback: () => disposeOrder.add('low'),
              ),
            )
            ..register(
              _LifecycleExtension(
                namespace: 'high',
                functions: [_fn('high_b')],
                onDisposeCallback: () => disposeOrder.add('high'),
                priority: 10,
              ),
            );

          await registry.attachTo(bridge);
          await registry.disposeAll();

          // Attach order: [high, low]; dispose order: reversed → [low, high].
          expect(disposeOrder, ['low', 'high']);
        },
      );

      test('registers extraFunctions onto bridge', () async {
        final bridge = _MockBridge();
        registry.register(
          _TestExtension(namespace: 'ns', functions: [_fn('ns_one')]),
        );

        await registry.attachTo(bridge, extraFunctions: [_fn('standalone_op')]);

        expect(bridge.registeredNames, contains('ns_one'));
        expect(bridge.registeredNames, contains('standalone_op'));
        expect(bridge.registeredNames, contains('help'));
      });

      test('extraFunctions with null or empty list is a no-op', () async {
        final bridge = _MockBridge();
        registry.register(
          _TestExtension(namespace: 'ns', functions: [_fn('ns_one')]),
        );

        await registry.attachTo(bridge, extraFunctions: []);

        expect(bridge.registeredNames, contains('ns_one'));
        expect(bridge.registeredNames, isNot(contains('standalone_op')));
      });

      test('attaches all plugins even if onAttach throws', () async {
        final bridge = _MockBridge();

        registry
          ..register(
            _LifecycleExtension(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onAttachCallback: () => throw Exception('aaa boom'),
            ),
          )
          ..register(
            _LifecycleExtension(namespace: 'bbb', functions: [_fn('bbb_x')]),
          );

        await expectLater(
          registry.attachTo(bridge),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('1 extension(s)'), contains('aaa')),
            ),
          ),
        );

        // Both plugins' functions were registered onto the bridge.
        expect(bridge.registeredNames, contains('aaa_x'));
        expect(bridge.registeredNames, contains('bbb_x'));
        expect(bridge.registeredNames, contains('help'));
      });

      group('coordinator injection', () {
        test(
          'coordinator is set on each extension before onAttach fires',
          () async {
            final bridge = _MockBridge();
            final plugin = _RegistryCapturingExtension(namespace: 'alpha');
            registry.register(plugin);
            await registry.attachTo(bridge);
            expect(plugin.capturedCoordinator, same(registry));
          },
        );

        test('accessing coordinator before attachTo throws', () {
          final plugin = _LifecycleExtension(namespace: 'lc', functions: []);
          // Accessing an uninitialised late field throws
          // LateInitializationError, a subtype of Error.
          expect(() => plugin.coordinator, throwsA(isA<Error>()));
        });
      });

      group('OS contributions', () {
        test(
          'single plugin contribution registers a provider on the bridge',
          () async {
            final bridge = _MockBridge();
            registry.register(
              _OsContribExtension(
                namespace: 'fs',
                contribution: {'Path.': _fakeOsHandler},
              ),
            );
            await registry.attachTo(bridge);
            expect(bridge.capturedOs, isNotNull);
          },
        );

        test(
          'no contributions and no baseOs — registerOs is not called',
          () async {
            final bridge = _MockBridge();
            registry.register(
              _TestExtension(namespace: 'ns', functions: [_fn('ns_x')]),
            );
            await registry.attachTo(bridge);
            expect(bridge.capturedOs, isNull);
          },
        );

        test(
          'baseOs alone is registered directly when there are no contributions',
          () async {
            final bridge = _MockBridge();
            const baseOs = _fakeOsHandler;
            registry.register(
              _TestExtension(namespace: 'ns', functions: [_fn('ns_x')]),
            );
            await registry.attachTo(bridge, baseOs: baseOs);
            expect(bridge.capturedOs, same(baseOs));
          },
        );

        test(
          'plugin contributions and baseOs are composed into a single provider',
          () async {
            final bridge = _MockBridge();
            registry.register(
              _OsContribExtension(
                namespace: 'fs',
                contribution: {'Path.': _fakeOsHandler},
              ),
            );
            const baseOs = _fakeOsHandler;
            await registry.attachTo(bridge, baseOs: baseOs);
            // A composed provider is registered — not baseOs directly.
            expect(bridge.capturedOs, isNotNull);
            expect(bridge.capturedOs, isNot(same(baseOs)));
          },
        );

        test(
          'overlapping OS prefixes between plugins throw StateError',
          () async {
            final bridge = _MockBridge();
            registry
              ..register(
                _OsContribExtension(
                  namespace: 'fs',
                  contribution: {'Path.': _fakeOsHandler},
                ),
              )
              ..register(
                _OsContribExtension(
                  namespace: 'other',
                  contribution: {'Path.': _fakeOsHandler},
                ),
              );
            await expectLater(
              registry.attachTo(bridge),
              throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'message',
                  allOf(contains('Path.'), contains('fs'), contains('other')),
                ),
              ),
            );
          },
        );
      });
    });

    group('disposeAll', () {
      test('calls onDispose in reverse registration order', () async {
        final order = <String>[];

        registry
          ..register(
            _LifecycleExtension(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => order.add('aaa'),
            ),
          )
          ..register(
            _LifecycleExtension(
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
          _LifecycleExtension(
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
            _LifecycleExtension(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => disposed.add('aaa'),
            ),
          )
          ..register(
            _LifecycleExtension(
              namespace: 'bbb',
              functions: [_fn('bbb_x')],
              onDisposeCallback: () => throw Exception('bbb boom'),
            ),
          )
          ..register(
            _LifecycleExtension(
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
              allOf(contains('1 extension(s)'), contains('bbb')),
            ),
          ),
        );

        // All three were attempted (reverse order: ccc, bbb, aaa).
        expect(disposed, ['ccc', 'aaa']);
      });

      test('collects multiple dispose errors', () async {
        registry
          ..register(
            _LifecycleExtension(
              namespace: 'aaa',
              functions: [_fn('aaa_x')],
              onDisposeCallback: () => throw Exception('aaa fail'),
            ),
          )
          ..register(
            _LifecycleExtension(
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
              allOf(
                contains('2 extension(s)'),
                contains('aaa'),
                contains('bbb'),
              ),
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
          _TestExtension(
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
                handler: (args, _) async => null,
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
          _TestExtension(
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
                handler: (args, _) async => null,
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
            _TestExtension(
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
          _TestExtension(namespace: 'ns', functions: [_fn('ns_one')]),
        );

        final prompt = registry.generateSystemPrompt();

        expect(prompt, startsWith('### ns'));
      });

      test('empty systemPromptPrefix produces no prefix', () {
        registry
          ..systemPromptPrefix = ''
          ..register(
            _TestExtension(namespace: 'ns', functions: [_fn('ns_one')]),
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
            _TestExtension(
              namespace: 'alpha',
              systemPromptContext: 'Alpha stuff.',
              functions: [_fn('alpha_one')],
            ),
          )
          ..register(
            _TestExtension(
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

    group('statefulObservations', () {
      test('returns empty iterable when no stateful plugins registered', () {
        registry.register(_TestExtension(namespace: 'ns', functions: []));

        expect(registry.statefulObservations(), isEmpty);
      });

      test('yields one pair per StatefulExtension', () {
        registry
          ..register(_StatefulTestPlugin(namespace: 'alpha', initial: 'a'))
          ..register(_StatefulTestPlugin(namespace: 'beta', initial: 'b'));

        final observations = registry.statefulObservations().toList();

        expect(observations, hasLength(2));
        expect(observations[0].$1, 'alpha');
        expect(observations[1].$1, 'beta');
      });

      test('skips plain (non-stateful) plugins', () {
        registry
          ..register(_TestExtension(namespace: 'plain', functions: []))
          ..register(_StatefulTestPlugin(namespace: 'stateful', initial: 0));

        final observations = registry.statefulObservations().toList();

        expect(observations, hasLength(1));
        expect(observations.first.$1, 'stateful');
      });

      test('signal value reflects current plugin state', () {
        final plugin = _StatefulTestPlugin(namespace: 'counter', initial: 0);
        registry.register(plugin);

        final (_, signal) = registry.statefulObservations().first;

        expect(signal.value, 0);

        plugin.state = 42;
        expect(signal.value, 42);
      });

      test('stateSignalAsObject returns covariant-erased signal', () {
        final plugin = _StatefulTestPlugin(namespace: 'typed', initial: 'x');
        registry.register(plugin);

        final (_, signal) = registry.statefulObservations().first;

        expect(signal, isA<ReadonlySignal<Object?>>());
        expect(signal.value, 'x');
      });
    });

    group('spawnChild — extraFunctions childPropagation', () {
      HostFunction extraFn(
        String name, {
        HostFunctionChildPropagation propagation =
            HostFunctionChildPropagation.exclude,
      }) => HostFunction(
        schema: HostFunctionSchema(name: name, description: ''),
        handler: (args, _) async => null,
        childPropagation: propagation,
      );

      test('excludes extras by default from child surface', () async {
        final parentBridge = _MockBridge();
        registry.register(_TestExtension(namespace: 'ns', functions: []));
        await registry.attachTo(
          parentBridge,
          extraFunctions: [extraFn('parent_only')],
        );

        final childBridge = _MockBridge();
        await registry.spawnChild(
          context: const ChildSpawnContext(childId: 1),
          bridge: childBridge,
        );

        expect(parentBridge.registeredNames, contains('parent_only'));
        expect(childBridge.registeredNames, isNot(contains('parent_only')));
      });

      test('propagates inherit-tagged extras to child surface', () async {
        final parentBridge = _MockBridge();
        registry.register(_TestExtension(namespace: 'ns', functions: []));
        await registry.attachTo(
          parentBridge,
          extraFunctions: [
            extraFn(
              'shared_tool',
              propagation: HostFunctionChildPropagation.inherit,
            ),
            extraFn('parent_only'),
          ],
        );

        final childBridge = _MockBridge();
        await registry.spawnChild(
          context: const ChildSpawnContext(childId: 2),
          bridge: childBridge,
        );

        expect(childBridge.registeredNames, contains('shared_tool'));
        expect(childBridge.registeredNames, isNot(contains('parent_only')));
      });

      test('defaults to exclude when childPropagation is not specified', () {
        final fn = HostFunction(
          schema: const HostFunctionSchema(name: 'x', description: ''),
          handler: (args, _) async => null,
        );

        expect(fn.childPropagation, HostFunctionChildPropagation.exclude);
      });
    });
  });
}

/// Plugin that mixes in `StatefulExtension` for testing `statefulObservations`.
class _StatefulTestPlugin<T> extends MontyExtension with StatefulExtension<T> {
  _StatefulTestPlugin({required this.namespace, required T initial}) {
    setInitialState(initial);
  }

  @override
  final String namespace;

  @override
  List<HostFunction> get functions => [];
}

/// Plugin with configurable lifecycle callbacks for testing.
class _LifecycleExtension extends MontyExtension {
  _LifecycleExtension({
    required this.namespace,
    required this.functions,
    this.onAttachCallback,
    this.onDisposeCallback,
    int priority = 0,
  }) : _priority = priority;

  @override
  final String namespace;

  @override
  final String? systemPromptContext = null;

  @override
  final List<HostFunction> functions;

  final int _priority;

  @override
  int get priority => _priority;

  final void Function()? onAttachCallback;
  final void Function()? onDisposeCallback;

  @override
  Future<void> onAttach(AttachContext host) async {
    await super.onAttach(host);
    onAttachCallback?.call();
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    onDisposeCallback?.call();
  }
}

/// Fake [OsCallHandler] — resolves to nothing, never actually invoked in tests.
Future<Object?> _fakeOsHandler(
  String operation,
  List<Object?> args,
  Map<String, Object?>? kwargs,
) => throw UnimplementedError();

/// Plugin with a configurable [osContribution] for OS prefix merging tests.
class _OsContribExtension extends MontyExtension {
  _OsContribExtension({
    required this.namespace,
    required Map<String, OsCallHandler>? contribution,
  }) : _contribution = contribution;

  @override
  final String namespace;

  @override
  List<HostFunction> get functions => [];

  final Map<String, OsCallHandler>? _contribution;

  @override
  Map<String, OsCallHandler>? get osContribution => _contribution;
}

/// Extension that captures its [coordinator] reference during [onAttach].
///
/// Used to verify that `ExtensionCoordinator` injects the coordinator before
/// the first [onAttach] call.
class _RegistryCapturingExtension extends MontyExtension {
  _RegistryCapturingExtension({required this.namespace});

  @override
  final String namespace;

  @override
  List<HostFunction> get functions => [];

  ExtensionCoordinator? capturedCoordinator;

  @override
  Future<void> onAttach(AttachContext host) async {
    await super.onAttach(host);
    capturedCoordinator = coordinator;
  }
}

/// Minimal bridge mock that tracks registered function names.
class _MockBridge implements MontyBridge {
  final registeredNames = <String>[];
  final _functions = <String, HostFunction>{};
  final _categoryIndex = <String, Set<String>>{};

  @override
  BridgeLogger get logger => const NullBridgeLogger();

  @override
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  @override
  List<HostFunctionSchema> get llmSchemas => const [];

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory {
    final result = <String, List<HostFunctionSchema>>{};
    for (final entry in _categoryIndex.entries) {
      final schemas = <HostFunctionSchema>[];
      for (final name in entry.value) {
        final fn = _functions[name];
        if (fn != null) schemas.add(fn.schema);
      }
      if (schemas.isNotEmpty) result[entry.key] = schemas;
    }
    return result;
  }

  @override
  void register(HostFunction function, {String? category}) {
    final name = function.schema.name;
    registeredNames.add(name);
    _functions[name] = function;
    final cat = category ?? 'uncategorized';
    (_categoryIndex[cat] ??= {}).add(name);
  }

  @override
  void unregister(String name) {}

  OsCallHandler? capturedOs;

  @override
  void registerOs(OsCallHandler handler) {
    capturedOs = handler;
  }

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
