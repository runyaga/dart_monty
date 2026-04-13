import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/message_bus_plugin.dart';
import 'package:signals_core/signals_core.dart';

// ---------------------------------------------------------------------------
// CronPlugin
// ---------------------------------------------------------------------------

enum _JobState { active, paused, cancelled }

class _CronJob {
  _CronJob({
    required this.id,
    required this.expression,
    required this.channel,
    this.label,
    this.maxFires = 0,
  });

  final String id;
  final String expression;
  final String channel;
  final String? label;
  final int maxFires;
  _JobState state = _JobState.active;
  int fireCount = 0;
  Timer? timer;
  DateTime? nextFireAt;

  Map<String, Object?> toMap() => {
    'job_id': id,
    'expression': expression,
    'channel': channel,
    'label': label,
    'state': state.name,
    'fire_count': fireCount,
    'next_fire_at_ms': nextFireAt?.millisecondsSinceEpoch,
  };
}

/// Plugin for scheduling recurring or one-shot jobs that post to MessageBus.
class CronPlugin extends MontyPlugin {
  CronPlugin({MessageBus? bus, this.maxJobs = 64}) : _bus = bus;

  final MessageBus? _bus;
  final int maxJobs;
  final Map<String, _CronJob> _jobs = {};
  bool _isDisposed = false;
  int _idCounter = 0;

  late final Signal<List<Map<String, Object?>>> _jobsSignal = signal(const []);
  late final ReadonlySignal<List<Map<String, Object?>>> jobsSignal =
      _jobsSignal;

  @override
  String get namespace => 'cron';

  @override
  String? get systemPromptContext =>
      'Schedule named, recurring or one-shot jobs using cron or interval expressions. '
      'Jobs post payloads to MessageBus channels. '
      'Supported expressions: periodic:<ms>, delay:<ms>, cron:<5-field-expr>.';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _cronScheduleSchema, handler: _handleSchedule),
    HostFunction(schema: _cronCancelSchema, handler: _handleCancel),
    HostFunction(schema: _cronPauseSchema, handler: _handlePause),
    HostFunction(schema: _cronResumeSchema, handler: _handleResume),
    HostFunction(schema: _cronListSchema, handler: _handleList),
    HostFunction(schema: _cronJobInfoSchema, handler: _handleJobInfo),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    // Shared bus (if available), independent job map.
    return CronPlugin(bus: _bus ?? sibling<MessageBusPlugin>()?.bus);
  }

  @override
  Future<void> onDispose() async {
    _isDisposed = true;
    for (final job in _jobs.values) {
      job.timer?.cancel();
    }
    _jobs.clear();
    _updateSignal();
    await super.onDispose();
  }

  MessageBus _getBus() {
    final bus = _bus ?? sibling<MessageBusPlugin>()?.bus;
    if (bus == null) {
      throw StateError(
        'CronPlugin requires a MessageBus. Register MessageBusPlugin first.',
      );
    }
    return bus;
  }

  Future<Object?> _handleSchedule(Map<String, Object?> args) async {
    if (_jobs.length >= maxJobs) {
      throw StateError('Maximum job limit ($maxJobs) reached.');
    }

    final expression = args['expression']! as String;
    final channel = args['channel']! as String;
    final label = args['label'] as String?;
    final maxFires = args['max_fires'] as int? ?? 0;

    final id = 'job_${++_idCounter}';
    final job = _CronJob(
      id: id,
      expression: expression,
      channel: channel,
      label: label,
      maxFires: maxFires,
    );

    _jobs[id] = job;
    _arm(job);
    _updateSignal();

    return id;
  }

  Future<Object?> _handleCancel(Map<String, Object?> args) async {
    final id = args['job_id']! as String;
    final job = _jobs.remove(id);
    if (job != null) {
      job.timer?.cancel();
      job.state = _JobState.cancelled;
      _updateSignal();
    }
    return null;
  }

  Future<Object?> _handlePause(Map<String, Object?> args) async {
    final id = args['job_id']! as String;
    final job = _jobs[id];
    if (job != null && job.state == _JobState.active) {
      job.timer?.cancel();
      job.timer = null;
      job.state = _JobState.paused;
      job.nextFireAt = null;
      _updateSignal();
    }
    return null;
  }

  Future<Object?> _handleResume(Map<String, Object?> args) async {
    final id = args['job_id']! as String;
    final job = _jobs[id];
    if (job != null && job.state == _JobState.paused) {
      job.state = _JobState.active;
      _arm(job);
      _updateSignal();
    }
    return null;
  }

  Future<Object?> _handleList(Map<String, Object?> args) async {
    return _jobs.values.map((j) => j.toMap()).toList();
  }

  Future<Object?> _handleJobInfo(Map<String, Object?> args) async {
    final id = args['job_id']! as String;
    return _jobs[id]?.toMap();
  }

  void _arm(_CronJob job) {
    if (_isDisposed) return;

    if (job.expression.startsWith('periodic:')) {
      final ms = int.tryParse(job.expression.substring(9));
      if (ms == null) throw FormatException('Invalid periodic expression');
      job.nextFireAt = DateTime.now().add(Duration(milliseconds: ms));
      job.timer = Timer.periodic(Duration(milliseconds: ms), (t) => _fire(job));
    } else if (job.expression.startsWith('delay:')) {
      final ms = int.tryParse(job.expression.substring(6));
      if (ms == null) throw FormatException('Invalid delay expression');
      job.nextFireAt = DateTime.now().add(Duration(milliseconds: ms));
      job.timer = Timer(Duration(milliseconds: ms), () => _fire(job));
    } else if (job.expression.startsWith('cron:')) {
      _armCron(job);
    } else {
      throw FormatException('Unsupported expression format: ${job.expression}');
    }
  }

  void _armCron(_CronJob job) {
    final expr = job.expression.substring(5);
    final next = _nextCronFire(expr, DateTime.now());
    job.nextFireAt = next;
    final delay = next.difference(DateTime.now());
    job.timer = Timer(delay, () {
      _fire(job);
      if (job.state == _JobState.active) {
        _armCron(job);
      }
    });
  }

  void _fire(_CronJob job) {
    if (_isDisposed) return;

    job.fireCount++;
    final payload = {
      'job_id': job.id,
      'label': job.label,
      'fire_count': job.fireCount,
      'fired_at_ms': DateTime.now().millisecondsSinceEpoch,
    };

    try {
      _getBus().send(job.channel, payload);
      logger.debug(
        'cron_fire',
        attributes: {'job_id': job.id, 'channel': job.channel},
      );
    } catch (e) {
      logger.warning(
        'cron_fire failed',
        attributes: {'job_id': job.id, 'error': e.toString()},
      );
      _handleCancel({'job_id': job.id});
      return;
    }

    if (job.maxFires > 0 && job.fireCount >= job.maxFires) {
      _handleCancel({'job_id': job.id});
    } else {
      _updateSignal();
    }
  }

  void _updateSignal() {
    _jobsSignal.value = _jobs.values.map((j) => j.toMap()).toList();
  }

  DateTime _nextCronFire(String expr, DateTime from) {
    // Minimal 5-field cron parser (minutes only for v1).
    // In a real implementation, we'd use a package or a full parser.
    // For now, we'll just increment by 1 minute if it's "* * * * *".
    if (expr.trim() == '* * * * *') {
      return from
          .add(const Duration(minutes: 1))
          .subtract(
            Duration(
              seconds: from.second,
              milliseconds: from.millisecond,
              microseconds: from.microsecond,
            ),
          );
    }
    // TODO: Implement full 5-field parser.
    throw UnimplementedError('Full cron parsing not implemented in v1');
  }
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const _cronScheduleSchema = HostFunctionSchema(
  name: 'cron_schedule',
  description: 'Register a named, recurring or one-shot job.',
  params: [
    HostParam(
      name: 'expression',
      type: HostParamType.string,
      description: 'periodic:<ms>, delay:<ms>, or cron:<expr>.',
    ),
    HostParam(
      name: 'channel',
      type: HostParamType.string,
      description: 'MessageBus channel to post to.',
    ),
    HostParam(
      name: 'label',
      type: HostParamType.string,
      isRequired: false,
      description: 'Optional metadata label.',
    ),
    HostParam(
      name: 'max_fires',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Limit number of fires (0=infinite).',
    ),
  ],
);

const _cronCancelSchema = HostFunctionSchema(
  name: 'cron_cancel',
  description: 'Cancel a job by ID.',
  params: [
    HostParam(
      name: 'job_id',
      type: HostParamType.string,
      description: 'Job ID.',
    ),
  ],
);

const _cronPauseSchema = HostFunctionSchema(
  name: 'cron_pause',
  description: 'Pause an active job.',
  params: [
    HostParam(
      name: 'job_id',
      type: HostParamType.string,
      description: 'Job ID.',
    ),
  ],
);

const _cronResumeSchema = HostFunctionSchema(
  name: 'cron_resume',
  description: 'Resume a paused job.',
  params: [
    HostParam(
      name: 'job_id',
      type: HostParamType.string,
      description: 'Job ID.',
    ),
  ],
);

const _cronListSchema = HostFunctionSchema(
  name: 'cron_list',
  description: 'List all registered jobs.',
  params: [],
);

const _cronJobInfoSchema = HostFunctionSchema(
  name: 'cron_job_info',
  description: 'Get details for a single job.',
  params: [
    HostParam(
      name: 'job_id',
      type: HostParamType.string,
      description: 'Job ID.',
    ),
  ],
);
