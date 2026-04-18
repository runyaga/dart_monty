import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/src/bridge/bridge/host_args.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:signals_core/signals_core.dart';

// ---------------------------------------------------------------------------
// ChannelSnapshot — immutable telemetry snapshot for a MessageChannel.
// ---------------------------------------------------------------------------

/// An immutable snapshot of a [MessageChannel]'s state at a point in time.
///
/// Emitted by [MessageChannel.snapshotSignal] on every state transition.
/// Suitable for reactive display in UI or for metrics collection:
///
/// ```dart
/// effect(() {
///   final s = bus.channel('results').snapshotSignal.value;
///   print('queue: ${s.queueDepth}, closed: ${s.isClosed}');
/// });
/// ```
class ChannelSnapshot {
  /// Creates a [ChannelSnapshot].
  const ChannelSnapshot({
    required this.isClosed,
    required this.queueDepth,
    required this.sendCount,
    required this.recvCount,
    required this.peakQueueDepth,
  });

  /// The initial state for a newly created channel.
  static const empty = ChannelSnapshot(
    isClosed: false,
    queueDepth: 0,
    sendCount: 0,
    recvCount: 0,
    peakQueueDepth: 0,
  );

  /// Whether the channel has been closed.
  final bool isClosed;

  /// Number of messages currently queued (unread).
  final int queueDepth;

  /// Total messages sent on this channel.
  final int sendCount;

  /// Total messages received (dequeued) on this channel.
  final int recvCount;

  /// Highest queue depth observed since the channel was created.
  final int peakQueueDepth;

  /// Returns a copy with the given fields replaced.
  ChannelSnapshot copyWith({
    bool? isClosed,
    int? queueDepth,
    int? sendCount,
    int? recvCount,
    int? peakQueueDepth,
  }) => ChannelSnapshot(
    isClosed: isClosed ?? this.isClosed,
    queueDepth: queueDepth ?? this.queueDepth,
    sendCount: sendCount ?? this.sendCount,
    recvCount: recvCount ?? this.recvCount,
    peakQueueDepth: peakQueueDepth ?? this.peakQueueDepth,
  );

  @override
  String toString() =>
      'ChannelSnapshot(isClosed: $isClosed, queueDepth: $queueDepth, '
      'sendCount: $sendCount, recvCount: $recvCount, '
      'peakQueueDepth: $peakQueueDepth)';
}

// ---------------------------------------------------------------------------
// MessageChannel — observable named channel primitive.
// ---------------------------------------------------------------------------

/// A named, FIFO message channel with reactive state.
///
/// [MessageChannel] is the first-class Dart primitive for communicating
/// between Python sandboxes and Dart code. It is usable directly from Dart
/// as well as through Python host functions (`msg_send`, `msg_recv`).
///
/// Obtain a channel via [MessageBus.channel]. Observe state changes
/// reactively via [snapshotSignal]:
///
/// ```dart
/// final ch = bus.channel('results');
/// effect(() => print(ch.snapshotSignal.value));
///
/// // Dart → Python: push a task
/// ch.send({'file': 'data.txt'});
///
/// // Dart ← Python: pull a result (async)
/// final result = await ch.recv();
/// ```
class MessageChannel {
  /// Creates a [MessageChannel] with empty state.
  MessageChannel();

  /// Reactive snapshot of this channel's current state.
  ///
  /// Updated on every [send], [recv], and [close] call.
  ReadonlySignal<ChannelSnapshot> get snapshotSignal => _snapshotSignal;

  final Signal<ChannelSnapshot> _snapshotSignal = signal(ChannelSnapshot.empty);

  final Queue<Object?> _queue = Queue();
  final List<Completer<Object?>> _waiters = [];

  /// The current snapshot (non-reactive one-shot read).
  ChannelSnapshot get snapshot => _snapshotSignal.value;

  /// Whether this channel has been closed.
  bool get isClosed => _snapshotSignal.value.isClosed;

  /// Enqueues [message], waking the first blocked [recv] if present.
  ///
  /// Throws [StateError] if the channel is closed.
  void send(Object? message) {
    final s = _snapshotSignal.value;
    if (s.isClosed) {
      throw StateError('Cannot send on a closed channel.');
    }

    // Fast path: hand directly to a waiting receiver.
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete(message);
        _snapshotSignal.value = s.copyWith(
          sendCount: s.sendCount + 1,
          recvCount: s.recvCount + 1,
        );

        return;
      }
    }

    // Slow path: enqueue for a future recv.
    _queue.add(message);
    final depth = _queue.length;
    _snapshotSignal.value = s.copyWith(
      sendCount: s.sendCount + 1,
      queueDepth: depth,
      peakQueueDepth: depth > s.peakQueueDepth ? depth : s.peakQueueDepth,
    );
  }

  /// Returns a future that resolves with the next message.
  ///
  /// - If messages are queued, resolves immediately.
  /// - If the channel is closed and empty, resolves with `null`.
  /// - Otherwise blocks until [send] or [close] is called.
  ///
  /// Pass [waiter] to allow external cancellation (e.g., timeout or disposal).
  Future<Object?> recv({Completer<Object?>? waiter}) {
    final s = _snapshotSignal.value;

    if (_queue.isNotEmpty) {
      final msg = _queue.removeFirst();
      _snapshotSignal.value = s.copyWith(
        recvCount: s.recvCount + 1,
        queueDepth: _queue.length,
      );

      return Future.value(msg);
    }

    if (s.isClosed) return Future.value();

    final c = waiter ?? Completer<Object?>();
    _waiters.add(c);

    return c.future;
  }

  /// Returns the front of the queue without removing it, or `null` if empty.
  Object? peek() => _queue.isEmpty ? null : _queue.first;

  /// Closes the channel, completing all pending [recv] futures with `null`.
  ///
  /// Idempotent — closing an already-closed channel is a no-op.
  /// Closed ≠ disposed: the snapshot remains readable after close. Call
  /// [dispose] when the channel object itself is no longer needed.
  void close() {
    final s = _snapshotSignal.value;
    if (s.isClosed) return;
    _snapshotSignal.value = s.copyWith(isClosed: true);
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete(null);
    }
    _waiters.clear();
  }

  /// Disposes the channel's signal.
  ///
  /// Called by [MessageBus.dispose]. After disposal, [snapshotSignal] must
  /// not be read. Callers should call [close] first to drain pending receivers.
  void dispose() => _snapshotSignal.dispose();

  /// Removes [waiter] from the pending receiver list.
  ///
  /// Used to cancel a timed-out or disposed recv without closing the channel.
  void removeWaiter(Completer<Object?> waiter) {
    _waiters.remove(waiter);
  }
}

// ---------------------------------------------------------------------------
// MessageBus — observable bus holding named channels.
// ---------------------------------------------------------------------------

/// An observable, in-memory message bus with named [MessageChannel]s.
///
/// Channels auto-create on first use via [channel]. Share a single [MessageBus]
/// instance across [MessageBusPlugin] parent and child instances for
/// transparent Python↔Python and Dart↔Python communication.
///
/// ```dart
/// final bus = MessageBus();
///
/// // Dart pushes a task; Python calls msg_recv('tasks') to pick it up.
/// bus.channel('tasks').send({'file': 'data.txt'});
///
/// // React to any channel activity.
/// effect(() => print(bus.channelsSignal.value.keys));
/// ```
class MessageBus {
  /// Creates an empty [MessageBus].
  MessageBus();

  /// Reactive map of all channels that have been accessed.
  ///
  /// A new entry is added whenever [channel] auto-creates a new channel.
  /// Each value is a [MessageChannel] whose own [MessageChannel.snapshotSignal]
  /// updates independently when messages flow through it.
  ReadonlySignal<Map<String, MessageChannel>> get channelsSignal =>
      _channelsSignal;

  final Map<String, MessageChannel> _channels = {};
  final Signal<Map<String, MessageChannel>> _channelsSignal = signal({});

  /// Returns the [MessageChannel] for [name], creating it if absent.
  ///
  /// Creating a new channel updates [channelsSignal].
  MessageChannel channel(String name) {
    final existing = _channels[name];
    if (existing != null) return existing;
    final ch = MessageChannel();
    _channels[name] = ch;
    _channelsSignal.value = Map.from(_channels);

    return ch;
  }

  /// Disposes the bus, all channels, and [_channelsSignal].
  void dispose() {
    for (final ch in _channels.values) {
      ch.dispose();
    }
    _channelsSignal.dispose();
  }

  /// Returns the [MessageChannel] for [name] if it exists, or `null`.
  ///
  /// Does NOT create a new channel — use [channel] for auto-creation.
  MessageChannel? channelOrNull(String name) => _channels[name];

  // ---------------------------------------------------------------------------
  // Convenience methods — delegate to channel(name).* for fluent bus usage.
  // ---------------------------------------------------------------------------

  /// Sends [message] on channel [name], creating the channel if needed.
  void send(String name, Object? message) => channel(name).send(message);

  /// Receives the next message from channel [name], creating it if needed.
  Future<Object?> recv(String name, {Completer<Object?>? waiter}) =>
      channel(name).recv(waiter: waiter);

  /// Peeks at the front of channel [name] without removing.
  Object? peek(String name) => channelOrNull(name)?.peek();

  /// Closes channel [name], creating it first if needed.
  void close(String name) => channel(name).close();

  /// Removes [waiter] from the pending receiver list of channel [name].
  void removeWaiter(String name, Completer<Object?> waiter) =>
      channelOrNull(name)?.removeWaiter(waiter);
}

// ---------------------------------------------------------------------------
// Schema constants for MessageBusPlugin host functions.
// ---------------------------------------------------------------------------

const _msgSendSchema = HostFunctionSchema(
  name: 'msg_send',
  description: 'Send a message on a named channel.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Channel name.',
    ),
    HostParam(
      name: 'message',
      type: HostParamType.any,
      description: 'Message payload (any serializable value).',
    ),
  ],
);

const _msgRecvSchema = HostFunctionSchema(
  name: 'msg_recv',
  description:
      'Receive the next message from a named channel. '
      'Blocks until a message is available or timeout expires.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Channel name.',
    ),
    HostParam(
      name: 'timeout_ms',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Timeout in milliseconds. Throws on expiry.',
    ),
  ],
);

const _msgPeekSchema = HostFunctionSchema(
  name: 'msg_peek',
  description:
      'Peek at the front of the queue without removing. '
      'Returns null if empty.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Channel name.',
    ),
  ],
);

const _msgCloseSchema = HostFunctionSchema(
  name: 'msg_close',
  description:
      'Close a channel. Pending receivers get null. '
      'Subsequent sends throw.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Channel name.',
    ),
  ],
);

const _msgStatsSchema = HostFunctionSchema(
  name: 'msg_stats',
  description: 'Get telemetry for a named channel.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Channel name.',
    ),
  ],
);

// ---------------------------------------------------------------------------
// MessageBusPlugin — thin Python adapter over MessageBus.
// ---------------------------------------------------------------------------

/// Plugin providing named, bidirectional, blocking message channels.
///
/// Parent and child sandbox interpreters share the same [MessageBus] instance,
/// enabling structured communication patterns like task distribution, progress
/// reporting, and coordinated multi-worker pipelines.
///
/// [MessageBus] is also directly usable from Dart — call
/// `bus.channel('name').send(x)` to push tasks from Dart to Python, or
/// `await bus.channel('name').recv()` to pull results back.
///
/// ## Cross-plugin access
///
/// After `PluginRegistry.attachTo` runs, other plugins can obtain a reference
/// via `sibling<MessageBusPlugin>()`:
///
/// ```dart
/// @override
/// Future<void> onRegister(MontyBridge bridge) async {
///   final bus = sibling<MessageBusPlugin>()?.bus;
///   bus?.channel('results').send({'status': 'ready'});
/// }
/// ```
class MessageBusPlugin extends MontyPlugin {
  /// Creates a [MessageBusPlugin].
  ///
  /// If [bus] is omitted a new [MessageBus] is created. Child instances
  /// returned by [createChildInstance] share the same bus.
  MessageBusPlugin({MessageBus? bus}) : _bus = bus ?? MessageBus();

  final MessageBus _bus;
  final Set<Completer<Object?>> _pendingRecvs = {};

  /// The backing bus, exposed for testing and Dart-side usage.
  MessageBus get bus => _bus;

  @override
  String get namespace => 'msg';

  @override
  String? get systemPromptContext =>
      'Send and receive structured messages on named channels. '
      'Use msg_send/msg_recv for blocking parent↔child communication. '
      'msg_peek checks without blocking. msg_close signals end-of-stream.';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _msgSendSchema, handler: _handleSend),
    HostFunction(schema: _msgRecvSchema, handler: _handleRecv),
    HostFunction(schema: _msgPeekSchema, handler: _handlePeek),
    HostFunction(schema: _msgCloseSchema, handler: _handleClose),
    HostFunction(schema: _msgStatsSchema, handler: _handleStats),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) =>
      MessageBusPlugin(bus: _bus);

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    for (final c in _pendingRecvs) {
      if (!c.isCompleted) {
        c.completeError(StateError('disposed'), StackTrace.current);
      }
    }
    _pendingRecvs.clear();
  }

  Future<Object?> _handleSend(Map<String, Object?> args) {
    final name = args.str('name');
    final message = args['message'];
    _bus.send(name, message);
    logger.debug('msg_send', attributes: {'channel': name});

    return Future.value();
  }

  Future<Object?> _handleRecv(Map<String, Object?> args) async {
    final name = args.str('name');
    final timeoutMs = args.intArgOrNull('timeout_ms');

    final completer = Completer<Object?>();
    _pendingRecvs.add(completer);

    try {
      final future = _bus.recv(name, waiter: completer);
      if (timeoutMs != null) {
        unawaited(future.catchError((_) => null));

        return await future.timeout(
          Duration(milliseconds: timeoutMs),
          onTimeout: () {
            _bus.removeWaiter(name, completer);
            throw StateError('msg_recv timed out after ${timeoutMs}ms');
          },
        );
      }

      return await future;
    } on Object {
      unawaited(completer.future.catchError((_) => null));
      rethrow;
    } finally {
      _pendingRecvs.remove(completer);
    }
  }

  Future<Object?> _handlePeek(Map<String, Object?> args) {
    final name = args.str('name');

    return Future.value(_bus.peek(name));
  }

  Future<Object?> _handleClose(Map<String, Object?> args) {
    final name = args.str('name');
    _bus.close(name);
    logger.debug('msg_close', attributes: {'channel': name});

    return Future.value();
  }

  Future<Object?> _handleStats(Map<String, Object?> args) {
    final name = args.str('name');
    final ch = _bus.channelOrNull(name);
    final s = ch?.snapshot ?? ChannelSnapshot.empty;

    return Future.value({
      'exists': ch != null,
      'closed': s.isClosed,
      'queue_depth': s.queueDepth,
      'send_count': s.sendCount,
      'recv_count': s.recvCount,
      'peak_queue_depth': s.peakQueueDepth,
    });
  }
}
