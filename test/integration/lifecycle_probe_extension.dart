import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// A public extension implemented entirely outside the package's library.
final class LifecycleProbeExtension extends MontyExtension {
  /// Creates independent state, optionally identifying a child clone.
  LifecycleProbeExtension({this.spawnContext});

  /// Context supplied by the parent coordinator when cloning.
  final ChildSpawnContext? spawnContext;

  /// Context observed by the attach hook.
  AttachContext? attachedTo;

  /// Last value stored by either Python or a direct Dart invocation.
  MontyValue? value;

  /// Number of successful store calls.
  int stores = 0;

  /// Number of effective disposals (repeated disposal is a no-op).
  int disposals = 0;

  @override
  String get namespace => 'lifecycle';

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'lifecycle_store',
        params: [HostParam(name: 'value', type: HostParamType.any)],
      ),
      handler: (args, _) async {
        value = args['value'];
        stores++;

        return value!;
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(name: 'lifecycle_read'),
      handler: (_, _) async => value ?? const MontyNone(),
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'lifecycle_checked',
        params: [HostParam(name: 'value', type: HostParamType.any)],
      ),
      handler: (args, _) async {
        const integer = HostParam(name: 'value', type: HostParamType.integer);

        return integer.validate(args['value']);
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'lifecycle_emit',
        params: [HostParam(name: 'text', type: HostParamType.string)],
      ),
      handler: (args, ctx) async {
        final text = (args['text']! as MontyString).value;
        ctx.emitText(text);

        return MontyInt(text.length);
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'lifecycle_log',
        params: [HostParam(name: 'level', type: HostParamType.string)],
      ),
      handler: (args, _) async {
        final level = (args['level']! as MontyString).value;
        final scoped = logger.child('handler');
        final attributes = <String, Object?>{'level': level};
        switch (level) {
          case 'trace':
            scoped.trace('probe log', attributes: attributes);
          case 'debug':
            scoped.debug('probe log', attributes: attributes);
          case 'info':
            scoped.info('probe log', attributes: attributes);
          case 'warning':
            scoped.warning('probe log', attributes: attributes);
          case 'error':
            scoped.error('probe log', attributes: attributes);
          default:
            throw ArgumentError.value(level, 'level');
        }

        return MontyString(level);
      },
    ),
  ];

  @override
  LifecycleProbeExtension createChildInstance(ChildSpawnContext context) =>
      LifecycleProbeExtension(spawnContext: context);

  @override
  Future<void> onAttach(AttachContext ctx) async {
    await super.onAttach(ctx);
    attachedTo = ctx;
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    if (disposals != 0) return;
    disposals++;
    value = null;
    attachedTo = null;
  }
}
