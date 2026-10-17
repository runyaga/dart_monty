import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
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
  handler: (args, _) async => const MontyNone(),
);

void main() {
  late ExtensionCoordinator registry;

  setUp(() {
    registry = ExtensionCoordinator();
  });

  test('AttachContext.schemas lists every registered function, and none '
      'without a handler on this backend', () async {
    final bridge = MontyBridge(
      session: FakeMontySession(),
      logger: BridgeLogger.silent,
    );
    addTearDown(bridge.dispose);
    List<String>? seen;
    registry
      ..register(
        _TestExtension(
          namespace: 'alpha',
          functions: [
            _fn('alpha_one'),
            const HostFunction(
              schema: HostFunctionSchema(name: 'alpha_none', description: ''),
            ),
          ],
        ),
      )
      ..register(
        _SchemaProbe(
          [_fn('probe_one')],
          (host) => seen = [for (final s in host.schemas) s.name],
        ),
      );

    await registry.attachTo(bridge, enableIntrospection: false);

    expect(seen, unorderedEquals(['alpha_one', 'probe_one']));
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

        test('coordinatorOf before attachTo throws StateError', () {
          final plugin = _LifecycleExtension(namespace: 'lc', functions: []);
          expect(() => coordinatorOf(plugin), throwsStateError);
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

        expect(count, 1); // Both callers join the same owner cleanup.
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

    group('spawnChild — extraFunctions', () {
      test('an extra function never reaches a child', () async {
        final parentBridge = _MockBridge();
        registry.register(_TestExtension(namespace: 'ns', functions: []));
        await registry.attachTo(
          parentBridge,
          extraFunctions: [
            HostFunction(
              schema: const HostFunctionSchema(name: 'parent_only'),
              handler: (args, _) async => const MontyNone(),
            ),
          ],
        );

        final childBridge = _MockBridge();
        await registry.spawnChild(
          context: const ChildSpawnContext(childId: 1),
          bridge: childBridge,
        );

        expect(parentBridge.registeredNames, contains('parent_only'));
        expect(childBridge.registeredNames, isNot(contains('parent_only')));
      });
    });

    group('extension ordering contract', () {
      test(
        'equal priorities keep registration order past insertion-sort size',
        () async {
          final attached = <String>[];
          final disposed = <String>[];
          // 40 extensions: List.sort switches from insertion sort (stable)
          // to quicksort (not stable) above 32 elements.
          for (var i = 0; i < 40; i++) {
            registry.register(
              _LifecycleExtension(
                namespace: 'e$i',
                functions: [],
                priority: i.isOdd ? 1 : 0,
                onAttachCallback: () => attached.add('e$i'),
                onDisposeCallback: () => disposed.add('e$i'),
              ),
            );
          }

          await registry.attachTo(_MockBridge());
          await registry.disposeAll();

          final expected = [
            for (var i = 1; i < 40; i += 2) 'e$i',
            for (var i = 0; i < 40; i += 2) 'e$i',
          ];
          expect(attached, expected);
          expect(disposed, expected.reversed.toList());
        },
      );

      test('a child: exclude absent, inherit shared, clone fresh', () async {
        final inherit = _PolicyExtension('inh', ChildPolicy.inherit);
        final clone = _PolicyExtension('cln', ChildPolicy.clone);
        registry
          ..register(_PolicyExtension('exc', ChildPolicy.exclude))
          ..register(inherit)
          ..register(clone);
        await registry.attachTo(_MockBridge());

        final child = await registry.spawnChild(
          context: const ChildSpawnContext(childId: 1),
          bridge: _MockBridge(),
        );

        final [first, second] = child.extensions;
        expect(first, same(inherit));
        expect(second, isNot(same(clone)));
        expect(second.namespace, 'cln');
        expect(coordinatorOf(second), same(child));
      });

      test(
        'a clone made before a failing createChildInstance is disposed',
        () async {
          final ok = _PolicyExtension('ok', ChildPolicy.clone);
          registry
            ..register(ok)
            ..register(
              _PolicyExtension(
                'bad',
                ChildPolicy.clone,
                onClone: () => throw StateError('no clone'),
              ),
            );
          await registry.attachTo(_MockBridge());

          await expectLater(
            registry.spawnChild(
              context: const ChildSpawnContext(childId: 1),
              bridge: _MockBridge(),
            ),
            throwsStateError,
          );

          expect(ok.clones.single.disposed, isTrue);
        },
      );

      test('rejected duplicate clone is disposed exactly once', () async {
        final first = _PolicyExtension('duplicate', ChildPolicy.clone);
        final second = _PolicyExtension('duplicate', ChildPolicy.clone);
        final clones = [first, second];
        registry
          ..register(
            _PolicyExtension(
              'first',
              ChildPolicy.clone,
              onClone: () => first,
            ),
          )
          ..register(
            _PolicyExtension(
              'second',
              ChildPolicy.clone,
              onClone: () => second,
            ),
          );
        await registry.attachTo(_MockBridge());
        addTearDown(registry.disposeAll);

        await expectLater(
          registry.spawnChild(
            context: const ChildSpawnContext(childId: 1),
            bridge: _MockBridge(),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('already registered'),
            ),
          ),
        );
        expect(clones.map((clone) => clone.disposals), [1, 1]);
      });

      test(
        'a clone owned before logging fails is disposed exactly once',
        () async {
          final clone = _LoggingFailureClone();
          registry.register(_CloneFactoryExtension(clone));
          await registry.attachTo(_MockBridge());

          await expectLater(
            registry.spawnChild(
              context: const ChildSpawnContext(childId: 1),
              bridge: _MockBridge(),
            ),
            throwsStateError,
          );

          expect(clone.disposals, 1);
        },
      );

      test('a clone extension without createChildInstance fails the spawn '
          'with UnsupportedError', () async {
        registry.register(_TestCloneWithoutFactory());
        await registry.attachTo(_MockBridge());

        await expectLater(
          registry.spawnChild(
            context: const ChildSpawnContext(childId: 1),
            bridge: _MockBridge(),
          ),
          throwsUnsupportedError,
        );
      });

      test("each extension's logger is the bridge logger's child, set "
          'before any onAttach', () async {
        final bridge = _LoggingBridge();
        BridgeLogger? seenByFirst;
        final first = _LifecycleExtension(namespace: 'aa', functions: []);
        registry
          ..register(
            _LifecycleExtension(
              namespace: 'zz',
              functions: [],
              priority: 1,
              onAttachCallback: () => seenByFirst = first.logger,
            ),
          )
          ..register(first);

        await registry.attachTo(bridge);

        expect(bridge.children, containsAll(['aa', 'zz']));
        expect(seenByFirst, same(bridge.childNamed('aa')));
      });

      test('an unsupported backend fails attach with an Error before any '
          'onAttach', () async {
        var attachedFirst = false;
        registry
          ..register(
            _LifecycleExtension(
              namespace: 'ok',
              functions: [],
              priority: 1,
              onAttachCallback: () => attachedFirst = true,
            ),
          )
          ..register(_WasmOnlyExtension());

        await expectLater(
          registry.attachTo(_MockBridge()),
          throwsA(
            isA<Error>().having((e) => '$e', 'text', contains('"wasmonly"')),
          ),
        );
        expect(attachedFirst, isFalse);
      });

      test('a failing onDispose during attach cleanup wins over the attach '
          'failure', () async {
        registry.register(
          _LifecycleExtension(
            namespace: 'boom',
            functions: [],
            onAttachCallback: () => throw StateError('attach'),
            onDisposeCallback: () => throw StateError('dispose'),
          ),
        );

        await expectLater(
          registry.attachTo(_MockBridge()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('failed to dispose'),
            ),
          ),
        );
      });
    });
  });
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

/// Fake [OsHandler] — resolves to nothing, never actually invoked in tests.
Future<MontyValue> _fakeOsHandler(
  String operation,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => throw UnimplementedError();

/// Plugin with a configurable [osContribution] for OS prefix merging tests.
class _OsContribExtension extends MontyExtension {
  _OsContribExtension({
    required this.namespace,
    required Map<String, OsHandler>? contribution,
  }) : _contribution = contribution;

  @override
  final String namespace;

  @override
  List<HostFunction> get functions => [];

  final Map<String, OsHandler>? _contribution;

  @override
  Map<String, OsHandler>? get osContribution => _contribution;
}

/// Extension that captures its coordinator ([coordinatorOf]) during
/// [onAttach].
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
    capturedCoordinator = coordinatorOf(this);
  }
}

/// Minimal bridge mock that tracks registered function names.
class _MockBridge implements MontyBridge {
  final registeredNames = <String>[];
  final _functions = <String, HostFunction>{};
  final _categoryIndex = <String, Set<String>>{};

  @override
  BridgeLogger get logger => BridgeLogger.silent;

  @override
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

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

  OsHandler? capturedOs;

  @override
  void registerOs(OsHandler handler) {
    capturedOs = handler;
  }

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

/// An extension that reports [AttachContext.schemas] from its `onAttach`.
class _SchemaProbe extends MontyExtension {
  _SchemaProbe(this.functions, this.onSchemas);

  @override
  final List<HostFunction> functions;

  final void Function(AttachContext host) onSchemas;

  @override
  String get namespace => 'probe';

  @override
  Future<void> onAttach(AttachContext host) async {
    await super.onAttach(host);
    onSchemas(host);
  }
}

/// An extension with [policy]; as a clone factory it records each clone,
/// or runs [onClone] instead when given.
class _PolicyExtension extends MontyExtension {
  _PolicyExtension(this.namespace, this.policy, {this.onClone});

  @override
  final String namespace;

  final ChildPolicy policy;
  final MontyExtension Function()? onClone;
  final List<_PolicyExtension> clones = [];
  bool disposed = false;
  int disposals = 0;

  @override
  List<HostFunction> get functions => [];

  @override
  ChildPolicy get childPolicy => policy;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) {
    final make = onClone;
    if (make != null) return make();
    final clone = _PolicyExtension(namespace, policy);
    clones.add(clone);

    return clone;
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    disposed = true;
    disposals++;
  }
}

/// A clone-policy extension that does not override createChildInstance.
class _TestCloneWithoutFactory extends MontyExtension {
  @override
  String get namespace => 'nofactory';

  @override
  List<HostFunction> get functions => [];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;
}

/// Produces a clone whose third `functions` read fails in `register`'s log.
class _CloneFactoryExtension extends MontyExtension {
  _CloneFactoryExtension(this.clone);

  final _LoggingFailureClone clone;

  @override
  String get namespace => 'factory';

  @override
  List<HostFunction> get functions => [];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) => clone;
}

class _LoggingFailureClone extends MontyExtension {
  int disposals = 0;
  var _functionsReads = 0;

  @override
  String get namespace => 'clone';

  @override
  List<HostFunction> get functions {
    if (++_functionsReads == 3) throw StateError('logging failed');

    return [];
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    disposals++;
  }
}

/// An extension that runs on the web backend only.
class _WasmOnlyExtension extends MontyExtension {
  @override
  String get namespace => 'wasmonly';

  @override
  List<HostFunction> get functions => [];

  @override
  Set<MontyBackendKind> get supportedBackends => const {MontyBackendKind.wasm};
}

/// A logger that names its children and records them.
final class _NamedLogger implements BridgeLogger {
  _NamedLogger(this.name, this.children);

  final String name;
  final Map<String, BridgeLogger> children;

  @override
  void trace(String message, {Map<String, Object?>? attributes}) {}

  @override
  void debug(String message, {Map<String, Object?>? attributes}) {}

  @override
  void info(String message, {Map<String, Object?>? attributes}) {}

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {}

  @override
  BridgeLogger child(String name) =>
      children[name] = _NamedLogger(name, children);

  @override
  void close() {}
}

/// A [_MockBridge] whose logger records the children made from it.
class _LoggingBridge extends _MockBridge {
  final Map<String, BridgeLogger> _children = {};

  late final BridgeLogger _logger = _NamedLogger('root', _children);

  @override
  BridgeLogger get logger => _logger;

  /// The names of the children made from [logger].
  Iterable<String> get children => _children.keys;

  /// The child named [name].
  BridgeLogger? childNamed(String name) => _children[name];
}
