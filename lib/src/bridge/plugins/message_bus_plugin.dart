import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';

/// A named, FIFO message channel with optional telemetry.
class _Channel {
  int sendCount = 0;
  int recvCount = 0;
  int peakQueueDepth = 0;
  final Queue<Object?> _queue = Queue();
  final List<Completer<Object?>> _waiters = [];
  bool _closed = false;
}

/// In-memory message bus with named channels.
///
/// Channels auto-create on first use. Messages are FIFO within each channel.
/// Multiple consumers are served in FIFO waiter order.
class MessageBus {
  final Map<String, _Channel> _channels = {};

  /// Enqueues [message] on channel [name], waking the first blocked receiver.
  ///
  /// Throws [StateError] if the channel is closed.
  void send(String name, Object? message) {
    final ch = _channel(name);
    if (ch._closed) {
      throw StateError('Cannot send on closed channel "$name".');
    }
    ch.sendCount++;
    if (ch._waiters.isNotEmpty) {
      final waiter = ch._waiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete(message);
        ch.recvCount++;

        return;
      }
    }
    ch._queue.add(message);
    if (ch._queue.length > ch.peakQueueDepth) {
      ch.peakQueueDepth = ch._queue.length;
    }
  }

  /// Returns a future that completes with the next message on channel [name].
  ///
  /// If messages are queued, returns immediately. If the channel is closed and
  /// empty, returns `null` without blocking. Otherwise blocks until a message
  /// arrives or the channel is closed.
  ///
  /// Pass [waiter] to allow external cancellation (e.g. timeout or disposal).
  Future<Object?> recv(String name, {Completer<Object?>? waiter}) {
    final ch = _channel(name);
    if (ch._queue.isNotEmpty) {
      ch.recvCount++;

      return Future.value(ch._queue.removeFirst());
    }
    if (ch._closed) {
      return Future.value();
    }
    final c = waiter ?? Completer<Object?>();
    ch._waiters.add(c);

    return c.future;
  }

  /// Returns the front of the queue without removing, or `null` if empty.
  Object? peek(String name) {
    final ch = _channels[name];
    if (ch == null || ch._queue.isEmpty) return null;

    return ch._queue.first;
  }

  /// Closes channel [name], completing all pending receivers with `null`.
  ///
  /// Idempotent — closing an already-closed channel is a no-op.
  void close(String name) {
    final ch = _channel(name);
    if (ch._closed) return;
    ch._closed = true;
    for (final w in ch._waiters) {
      if (!w.isCompleted) w.complete(null);
    }
    ch._waiters.clear();
  }

  /// Returns telemetry for channel [name].
  Map<String, Object?> stats(String name) {
    final ch = _channels[name];
    if (ch == null) {
      return {
        'exists': false,
        'closed': false,
        'queue_depth': 0,
        'send_count': 0,
        'recv_count': 0,
        'peak_queue_depth': 0,
      };
    }

    return {
      'exists': true,
      'closed': ch._closed,
      'queue_depth': ch._queue.length,
      'send_count': ch.sendCount,
      'recv_count': ch.recvCount,
      'peak_queue_depth': ch.peakQueueDepth,
    };
  }

  /// Removes [c] from the waiter list of channel [name].
  void removeWaiter(String name, Completer<Object?> c) {
    _channels[name]?._waiters.remove(c);
  }

  _Channel _channel(String name) => _channels.putIfAbsent(name, _Channel.new);
}

/// Plugin providing named, bidirectional, blocking message channels.
///
/// Parent and child sandbox interpreters share the same [MessageBus] instance,
/// enabling structured communication patterns like task distribution, progress
/// reporting, and coordinated multi-worker pipelines.
class MessageBusPlugin extends MontyPlugin {
  /// Creates a [MessageBusPlugin].
  ///
  /// If [bus] is omitted a new [MessageBus] is created. Child instances
  /// returned by [createChildInstance] share the same bus.
  MessageBusPlugin({MessageBus? bus}) : _bus = bus ?? MessageBus();

  final MessageBus _bus;
  final Set<Completer<Object?>> _pendingRecvs = {};

  /// The backing bus, exposed for testing.
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
    HostFunction(
      schema: const HostFunctionSchema(
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
      ),
      handler: _handleSend,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
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
      ),
      handler: _handleRecv,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
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
      ),
      handler: _handlePeek,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
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
      ),
      handler: _handleClose,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'msg_stats',
        description: 'Get telemetry for a named channel.',
        params: [
          HostParam(
            name: 'name',
            type: HostParamType.string,
            description: 'Channel name.',
          ),
        ],
      ),
      handler: _handleStats,
    ),
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
    final name = args['name']! as String;
    final message = args['message'];
    _bus.send(name, message);
    logger.debug('msg_send', attributes: {'channel': name});

    return Future.value();
  }

  Future<Object?> _handleRecv(Map<String, Object?> args) async {
    final name = args['name']! as String;
    final timeoutMs = args['timeout_ms'] as int?;

    final completer = Completer<Object?>();
    _pendingRecvs.add(completer);

    try {
      final future = _bus.recv(name, waiter: completer);
      if (timeoutMs != null) {
        // Drain the original future so a later error doesn't go uncaught
        // if the timeout fires before the recv completes.
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
      // Drain any lingering error on the completer so it does not surface
      // as an uncaught async error after we stop listening.
      unawaited(completer.future.catchError((_) => null));
      rethrow;
    } finally {
      _pendingRecvs.remove(completer);
    }
  }

  Future<Object?> _handlePeek(Map<String, Object?> args) {
    final name = args['name']! as String;

    return Future.value(_bus.peek(name));
  }

  Future<Object?> _handleClose(Map<String, Object?> args) {
    final name = args['name']! as String;
    _bus.close(name);
    logger.debug('msg_close', attributes: {'channel': name});

    return Future.value();
  }

  Future<Object?> _handleStats(Map<String, Object?> args) {
    final name = args['name']! as String;

    return Future.value(_bus.stats(name));
  }
}
