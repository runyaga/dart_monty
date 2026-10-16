import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// A test-local extension with shared state and per-instance ownership.
final class SharedProbeExtension extends MontyExtension {
  /// Creates a root fixture or a clone sharing the same backing state.
  SharedProbeExtension({Map<String, MontyValue>? values})
    : values = values ?? {} {
    // Tests may inspect ownership without awaiting this operation.
    pending.future.ignore();
  }

  /// State survives the disposal of an individual clone.
  final Map<String, MontyValue> values;

  /// An operation owned only by this instance, for teardown assertions.
  final pending = Completer<void>();

  @override
  String get namespace => 'probe';

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  SharedProbeExtension createChildInstance(ChildSpawnContext context) =>
      SharedProbeExtension(values: values);

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'probe_put',
        description: 'Store a fixture value',
        params: [
          HostParam(name: 'name', type: HostParamType.string),
          HostParam(name: 'value', type: HostParamType.any),
        ],
      ),
      handler: (args, _) async {
        values[(args['name']! as MontyString).value] = args['value']!;

        return const MontyNone();
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'probe_get',
        description: 'Read a fixture value',
        params: [HostParam(name: 'name', type: HostParamType.string)],
      ),
      handler: (args, _) async =>
          values[(args['name']! as MontyString).value] ?? const MontyNone(),
    ),
  ];

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    if (!pending.isCompleted) {
      pending.completeError(StateError('fixture disposed'), StackTrace.current);
    }
  }
}
