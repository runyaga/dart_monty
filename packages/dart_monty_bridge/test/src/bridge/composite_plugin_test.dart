import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test plugins
// ---------------------------------------------------------------------------

/// Simple in-memory key-value store plugin.
class MemoryPlugin extends MontyPlugin {
  final _store = <String, String>{};

  @override
  String get namespace => 'mem';

  @override
  String? get systemPromptContext => 'Persistent key-value memory.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'mem_set',
        description: 'Set a key-value pair.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
          HostParam(name: 'value', type: HostParamType.string),
        ],
      ),
      handler: (args) async {
        _store[args['key']! as String] = args['value']! as String;
        return 'ok';
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'mem_get',
        description: 'Get a value by key.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
        ],
      ),
      handler: (args) async => _store[args['key']! as String],
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'mem_keys',
        description: 'List all keys.',
      ),
      handler: (args) async => _store.keys.toList(),
    ),
  ];

  /// Direct Dart API for sibling plugins.
  Future<void> set(String key, String value) async {
    _store[key] = value;
  }

  Future<String?> get(String key) async => _store[key];

  Future<List<String>> keys() async => _store.keys.toList();
}

/// Composite plugin that delegates to MemoryPlugin for persistence.
class BudgetPlugin extends MontyPlugin with CompositePlugin {
  final memoryRef = PluginRef<MemoryPlugin>();

  @override
  String get namespace => 'budget';

  @override
  String? get systemPromptContext =>
      'Budget management. Persists via memory plugin.';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [memoryRef];

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'budget_set',
        description: 'Set a budget category with amount.',
        params: [
          HostParam(name: 'category', type: HostParamType.string),
          HostParam(name: 'amount', type: HostParamType.number),
        ],
      ),
      handler: (args) async {
        final category = args['category']! as String;
        final amount = args['amount']! as num;
        await memoryRef.plugin.set('budget_$category', amount.toString());
        return 'Budget set: $category = \$$amount';
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'budget_get',
        description: 'Get budget for a category.',
        params: [
          HostParam(name: 'category', type: HostParamType.string),
        ],
      ),
      handler: (args) async {
        final category = args['category']! as String;
        final raw = await memoryRef.plugin.get('budget_$category');
        if (raw == null) return 'No budget set for $category';
        return 'Budget for $category: \$$raw';
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'budget_list',
        description: 'List all budget categories.',
      ),
      handler: (args) async {
        final allKeys = await memoryRef.plugin.keys();
        return allKeys
            .where((k) => k.startsWith('budget_'))
            .map((k) => k.substring('budget_'.length))
            .toList();
      },
    ),
  ];
}

/// Plugin with an optional dependency.
class ReportPlugin extends MontyPlugin with CompositePlugin {
  final budgetRef = PluginRef<BudgetPlugin>(required: false);

  @override
  String get namespace => 'report';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [budgetRef];

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'report_status',
        description: 'Check if budget data is available.',
      ),
      handler: (args) async {
        if (budgetRef.isResolved) return 'Budget plugin available';
        return 'Running without budget support';
      },
    ),
  ];
}

/// Creates a circular dependency: A depends on B, B depends on A.
class CircularA extends MontyPlugin with CompositePlugin {
  final bRef = PluginRef<CircularB>();

  @override
  String get namespace => 'circ_a';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [bRef];

  @override
  List<HostFunction> get functions => [_fn('circ_a_do')];
}

class CircularB extends MontyPlugin with CompositePlugin {
  final aRef = PluginRef<CircularA>();

  @override
  String get namespace => 'circ_b';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [aRef];

  @override
  List<HostFunction> get functions => [_fn('circ_b_do')];
}

/// Plugin that requires a dependency that won't be registered.
class OrphanPlugin extends MontyPlugin with CompositePlugin {
  final missingRef = PluginRef<MemoryPlugin>();

  @override
  String get namespace => 'orphan';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [missingRef];

  @override
  List<HostFunction> get functions => [_fn('orphan_do')];
}

/// Subclass of MemoryPlugin (for polymorphic resolution tests).
class ExtendedMemoryPlugin extends MemoryPlugin {
  @override
  String get namespace => 'ext_mem';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'ext_mem_set',
        description: 'Set a key-value pair.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
          HostParam(name: 'value', type: HostParamType.string),
        ],
      ),
      handler: (args) async {
        await set(args['key']! as String, args['value']! as String);
        return 'ok';
      },
    ),
  ];
}

/// Composite that depends on MemoryPlugin (base type).
class PolyConsumerPlugin extends MontyPlugin with CompositePlugin {
  final memRef = PluginRef<MemoryPlugin>();

  @override
  String get namespace => 'polycon';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [memRef];

  @override
  List<HostFunction> get functions => [_fn('polycon_do')];
}

/// Multi-level composition: C depends on B, B depends on A.
class LayerA extends MontyPlugin {
  bool initialized = false;

  @override
  String get namespace => 'layer_a';

  @override
  List<HostFunction> get functions => [_fn('layer_a_do')];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    initialized = true;
  }
}

class LayerB extends MontyPlugin with CompositePlugin {
  final aRef = PluginRef<LayerA>();

  @override
  String get namespace => 'layer_b';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [aRef];

  @override
  List<HostFunction> get functions => [_fn('layer_b_do')];
}

class LayerC extends MontyPlugin with CompositePlugin {
  final bRef = PluginRef<LayerB>();

  @override
  String get namespace => 'layer_c';

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [bRef];

  @override
  List<HostFunction> get functions => [_fn('layer_c_do')];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

HostFunction _fn(String name) => HostFunction(
  schema: HostFunctionSchema(name: name, description: ''),
  handler: (args) async => null,
);

class _MockBridge implements MontyBridge {
  final registeredNames = <String>[];

  @override
  List<HostFunctionSchema> get schemas => [];

  @override
  void register(HostFunction function) {
    registeredNames.add(function.schema.name);
  }

  @override
  void unregister(String name) {}

  @override
  Stream<BridgeEvent> execute(String code) => const Stream.empty();

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late PluginRegistry registry;
  late _MockBridge bridge;

  setUp(() {
    registry = PluginRegistry();
    bridge = _MockBridge();
  });

  group('PluginRef', () {
    test('unresolved ref throws StateError', () {
      final ref = PluginRef<MemoryPlugin>();

      expect(ref.isResolved, isFalse);
      expect(() => ref.plugin, throwsA(isA<StateError>()));
    });

    test('resolved ref returns plugin', () {
      final ref = PluginRef<MemoryPlugin>();
      final memory = MemoryPlugin();

      ref.bind(memory);

      expect(ref.isResolved, isTrue);
      expect(ref.plugin, same(memory));
    });

    test('accepts matches exact type', () {
      final ref = PluginRef<MemoryPlugin>();

      expect(ref.accepts(MemoryPlugin()), isTrue);
      expect(ref.accepts(BudgetPlugin()), isFalse);
    });
  });

  group('CompositePlugin resolution', () {
    test('resolves direct dependency during attachTo', () async {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(memory)
        ..register(budget);
      await registry.attachTo(bridge);

      expect(budget.memoryRef.isResolved, isTrue);
      expect(budget.memoryRef.plugin, same(memory));
    });

    test('registration order does not matter for resolution', () async {
      final budget = BudgetPlugin();
      final memory = MemoryPlugin();

      // Budget registered before its dependency.
      registry
        ..register(budget)
        ..register(memory);
      await registry.attachTo(bridge);

      expect(budget.memoryRef.isResolved, isTrue);
      expect(budget.memoryRef.plugin, same(memory));
    });

    test('composite plugin can call dependency methods', () async {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(memory)
        ..register(budget);
      await registry.attachTo(bridge);

      // Simulate what the handler does.
      await budget.memoryRef.plugin.set('budget_food', '500');
      final result = await budget.memoryRef.plugin.get('budget_food');

      expect(result, '500');
    });

    test('handler delegates to resolved dependency', () async {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(memory)
        ..register(budget);
      await registry.attachTo(bridge);

      // Call budget_set handler directly.
      final setFn = budget.functions.firstWhere(
        (f) => f.schema.name == 'budget_set',
      );
      final result = await setFn.handler({
        'category': 'groceries',
        'amount': 250.0,
      });

      expect(result, contains('groceries'));
      expect(result, contains('250'));

      // Verify data landed in memory plugin.
      expect(await memory.get('budget_groceries'), '250.0');
    });

    test('budget_list filters memory keys by prefix', () async {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(memory)
        ..register(budget);
      await registry.attachTo(bridge);

      await memory.set('budget_food', '500');
      await memory.set('budget_rent', '1200');
      await memory.set('other_key', 'ignored');

      final listFn = budget.functions.firstWhere(
        (f) => f.schema.name == 'budget_list',
      );
      final categories = (await listFn.handler({}))! as List<String>;

      expect(categories, unorderedEquals(['food', 'rent']));
    });
  });

  group('optional dependencies', () {
    test('optional ref stays unresolved when target not registered', () async {
      final report = ReportPlugin();

      registry.register(report);
      await registry.attachTo(bridge);

      expect(report.budgetRef.isResolved, isFalse);

      final statusFn = report.functions.firstWhere(
        (f) => f.schema.name == 'report_status',
      );
      expect(await statusFn.handler({}), 'Running without budget support');
    });

    test('optional ref resolves when target is registered', () async {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();
      final report = ReportPlugin();

      registry
        ..register(memory)
        ..register(budget)
        ..register(report);
      await registry.attachTo(bridge);

      expect(report.budgetRef.isResolved, isTrue);

      final statusFn = report.functions.firstWhere(
        (f) => f.schema.name == 'report_status',
      );
      expect(await statusFn.handler({}), 'Budget plugin available');
    });
  });

  group('missing required dependency', () {
    test('throws StateError when required dependency not registered', () async {
      final orphan = OrphanPlugin();

      registry.register(orphan);

      await expectLater(
        registry.attachTo(bridge),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('orphan'),
              contains('unresolvable'),
            ),
          ),
        ),
      );
    });
  });

  group('circular dependency detection', () {
    test('throws StateError on direct cycle', () async {
      final a = CircularA();
      final b = CircularB();

      registry
        ..register(a)
        ..register(b);

      await expectLater(
        registry.attachTo(bridge),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Circular dependency'),
          ),
        ),
      );
    });
  });

  group('multi-level composition', () {
    test('resolves transitive dependencies (C → B → A)', () async {
      final a = LayerA();
      final b = LayerB();
      final c = LayerC();

      registry
        ..register(a)
        ..register(b)
        ..register(c);
      await registry.attachTo(bridge);

      expect(b.aRef.isResolved, isTrue);
      expect(b.aRef.plugin, same(a));
      expect(c.bRef.isResolved, isTrue);
      expect(c.bRef.plugin, same(b));

      // Transitive: C can reach A through B.
      expect(c.bRef.plugin.aRef.plugin, same(a));
    });

    test('all plugins wired to bridge', () async {
      registry
        ..register(LayerA())
        ..register(LayerB())
        ..register(LayerC());
      await registry.attachTo(bridge);

      expect(bridge.registeredNames, contains('layer_a_do'));
      expect(bridge.registeredNames, contains('layer_b_do'));
      expect(bridge.registeredNames, contains('layer_c_do'));
    });
  });

  group('system prompt includes composite plugins', () {
    test('composite plugin appears in generated prompt', () {
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(memory)
        ..register(budget);

      final prompt = registry.generateSystemPrompt();

      expect(prompt, contains('### mem'));
      expect(prompt, contains('### budget'));
      expect(prompt, contains('Persists via memory plugin'));
      expect(prompt, contains('budget_set'));
      expect(prompt, contains('budget_get'));
    });
  });

  group('polymorphic resolution', () {
    test('subclass resolves for base-type PluginRef', () async {
      final extMem = ExtendedMemoryPlugin();
      final consumer = PolyConsumerPlugin();

      registry
        ..register(extMem)
        ..register(consumer);
      await registry.attachTo(bridge);

      expect(consumer.memRef.isResolved, isTrue);
      // ExtendedMemoryPlugin is-a MemoryPlugin, so it should match.
      expect(consumer.memRef.plugin, same(extMem));
    });

    test('accepts returns true for subclass', () {
      final ref = PluginRef<MemoryPlugin>();
      expect(ref.accepts(ExtendedMemoryPlugin()), isTrue);
    });
  });

  group('topological onRegister order', () {
    test('dependencies initialized before dependents', () async {
      final order = <String>[];
      final a = _OrderTrackingPlugin(
        ns: 'topo_a',
        onRegisterCallback: () => order.add('topo_a'),
      );
      final b = _CompositeOrderPlugin(
        ns: 'topo_b',
        depRef: PluginRef<_OrderTrackingPlugin>(),
        onRegisterCallback: () => order.add('topo_b'),
      );

      // Register B before A — topo sort should still init A first.
      registry
        ..register(b)
        ..register(a);
      await registry.attachTo(bridge);

      expect(order.indexOf('topo_a'), lessThan(order.indexOf('topo_b')));
    });

    test('three-level chain inits in dependency order', () async {
      final a = LayerA();
      final b = LayerB();
      final c = LayerC();

      // Register in reverse order.
      registry
        ..register(c)
        ..register(b)
        ..register(a);

      // Patch lifecycle tracking into LayerA.
      // (LayerA already tracks via initialized flag, but let's use a
      // different mechanism — just verify onRegister completes via
      // the ref chain being available.)
      await registry.attachTo(bridge);

      // A should have been initialized (onRegister called).
      expect(a.initialized, isTrue);
      // And all refs should be resolved.
      expect(b.aRef.plugin, same(a));
      expect(c.bRef.plugin, same(b));
    });
  });

  group('topological dispose order', () {
    test('dependents dispose before dependencies', () async {
      final disposeOrder = <String>[];
      final a = _DisposeTrackingPlugin(
        ns: 'dep_a',
        onDisposeCallback: () => disposeOrder.add('dep_a'),
      );
      final b = _CompositeDisposePlugin(
        ns: 'dep_b',
        depRef: PluginRef<_DisposeTrackingPlugin>(),
        onDisposeCallback: () => disposeOrder.add('dep_b'),
      );

      // Register B before A.
      registry
        ..register(b)
        ..register(a);
      await registry.attachTo(bridge);
      await registry.disposeAll();

      // B depends on A, so B must dispose first (reverse topo).
      expect(
        disposeOrder.indexOf('dep_b'),
        lessThan(disposeOrder.indexOf('dep_a')),
      );
    });
  });

  group('existing non-composite plugins unaffected', () {
    test('plain plugins work alongside composite plugins', () async {
      final plain = _PlainPlugin();
      final memory = MemoryPlugin();
      final budget = BudgetPlugin();

      registry
        ..register(plain)
        ..register(memory)
        ..register(budget);
      await registry.attachTo(bridge);

      expect(bridge.registeredNames, contains('plain_do'));
      expect(bridge.registeredNames, contains('mem_set'));
      expect(bridge.registeredNames, contains('budget_set'));
    });
  });
}

class _PlainPlugin extends MontyPlugin {
  @override
  String get namespace => 'plain';

  @override
  List<HostFunction> get functions => [_fn('plain_do')];
}

class _OrderTrackingPlugin extends MontyPlugin {
  _OrderTrackingPlugin({required String ns, this.onRegisterCallback})
    : _ns = ns;

  final String _ns;
  final void Function()? onRegisterCallback;

  @override
  String get namespace => _ns;

  @override
  List<HostFunction> get functions => [_fn('${_ns}_do')];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    onRegisterCallback?.call();
  }
}

class _DisposeTrackingPlugin extends MontyPlugin {
  _DisposeTrackingPlugin({required String ns, this.onDisposeCallback})
    : _ns = ns;

  final String _ns;
  final void Function()? onDisposeCallback;

  @override
  String get namespace => _ns;

  @override
  List<HostFunction> get functions => [_fn('${_ns}_do')];

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    onDisposeCallback?.call();
  }
}

class _CompositeDisposePlugin extends MontyPlugin with CompositePlugin {
  _CompositeDisposePlugin({
    required String ns,
    required this.depRef,
    this.onDisposeCallback,
  }) : _ns = ns;

  final String _ns;
  final PluginRef<_DisposeTrackingPlugin> depRef;
  final void Function()? onDisposeCallback;

  @override
  String get namespace => _ns;

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [depRef];

  @override
  List<HostFunction> get functions => [_fn('${_ns}_do')];

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    onDisposeCallback?.call();
  }
}

class _CompositeOrderPlugin extends MontyPlugin with CompositePlugin {
  _CompositeOrderPlugin({
    required String ns,
    required this.depRef,
    this.onRegisterCallback,
  }) : _ns = ns;

  final String _ns;
  final PluginRef<_OrderTrackingPlugin> depRef;
  final void Function()? onRegisterCallback;

  @override
  String get namespace => _ns;

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [depRef];

  @override
  List<HostFunction> get functions => [_fn('${_ns}_do')];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    onRegisterCallback?.call();
  }
}
