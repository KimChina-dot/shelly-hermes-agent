import 'dart:async';
import 'dart:convert';

// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform/background_tasks.dart';

import '../core/gateway/openai_gateway.dart';
import '../core/models.dart';
import 'settings_store.dart';

/// How a scheduled task repeats after a run.
enum TaskRepeatMode { once, daily, weekly }

/// Outcome of the last run recorded for a task. `pending` means the task is
/// waiting for its next run; `done`/`failed` describe the last run (and are
/// terminal for one-shot tasks).
enum ScheduledTaskStatus { pending, done, failed }

/// One in-app scheduled agent task (PHASE 41). Records live in a single
/// JSON list under SharedPreferences; [at] carries the next scheduled run
/// as epoch milliseconds.
class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.prompt,
    required this.at,
    this.repeat = TaskRepeatMode.once,
    this.enabled = true,
    this.lastRunAt,
    this.result,
    this.status = ScheduledTaskStatus.pending,
  });

  final String id;
  final String prompt;

  /// The next scheduled run (local wall-clock). A value in the past means
  /// the task is overdue and waiting for its catch-up run.
  final DateTime at;
  final TaskRepeatMode repeat;
  final bool enabled;

  /// When the last run happened; null until the first run completes.
  final DateTime? lastRunAt;

  /// Reply text of the last run, or the failure description.
  final String? result;
  final ScheduledTaskStatus status;

  /// True when [SchedulerService.tick] should pick this task up at [now]:
  /// enabled, past its schedule, and — for one-shot tasks — not run yet.
  bool isDue(DateTime now) =>
      enabled &&
      !at.isAfter(now) &&
      (repeat != TaskRepeatMode.once ||
          status == ScheduledTaskStatus.pending);

  /// The next occurrence strictly after [after], stepping the schedule
  /// forward so a catch-up run that happens days late never re-enters the
  /// missed windows. One-shot tasks never move.
  DateTime nextOccurrenceAfter(DateTime after) {
    if (repeat == TaskRepeatMode.once) return at;
    final days = repeat == TaskRepeatMode.daily ? 1 : 7;
    var next = _shiftDays(at, days);
    while (!next.isAfter(after)) {
      next = _shiftDays(next, days);
    }
    return next;
  }

  /// Calendar-day shift (not a fixed duration) so the local wall-clock
  /// time-of-day survives across DST-affected dates.
  static DateTime _shiftDays(DateTime t, int days) => DateTime(
        t.year,
        t.month,
        t.day + days,
        t.hour,
        t.minute,
        t.second,
        t.millisecond,
        t.microsecond,
      );

  ScheduledTask copyWith({
    String? id,
    String? prompt,
    DateTime? at,
    TaskRepeatMode? repeat,
    bool? enabled,
    DateTime? lastRunAt,
    String? result,
    ScheduledTaskStatus? status,
  }) =>
      ScheduledTask(
        id: id ?? this.id,
        prompt: prompt ?? this.prompt,
        at: at ?? this.at,
        repeat: repeat ?? this.repeat,
        enabled: enabled ?? this.enabled,
        lastRunAt: lastRunAt ?? this.lastRunAt,
        result: result ?? this.result,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'at': at.millisecondsSinceEpoch,
        'repeat': repeat.name,
        'enabled': enabled,
        if (lastRunAt != null)
          'lastRunAt': lastRunAt!.millisecondsSinceEpoch,
        if (result != null) 'result': result,
        'status': status.name,
      };

  static ScheduledTask fromJson(Map<String, dynamic> json) => ScheduledTask(
        id: json['id'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        at: json['at'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['at'] as num).toInt(),
              )
            : DateTime.now(),
        repeat: TaskRepeatMode.values.asNameMap()[json['repeat']] ??
            TaskRepeatMode.once,
        enabled: json['enabled'] as bool? ?? true,
        lastRunAt: json['lastRunAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['lastRunAt'] as num).toInt(),
              )
            : null,
        result: json['result'] as String?,
        status: ScheduledTaskStatus.values.asNameMap()[json['status']] ??
            ScheduledTaskStatus.pending,
      );

  @override
  bool operator ==(Object other) =>
      other is ScheduledTask &&
      other.id == id &&
      other.prompt == prompt &&
      other.at == at &&
      other.repeat == repeat &&
      other.enabled == enabled &&
      other.lastRunAt == lastRunAt &&
      other.result == result &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, prompt, at, repeat, enabled, lastRunAt,
      result, status);

  @override
  String toString() => 'ScheduledTask($id, ${repeat.name}, $at, $status)';
}

/// CRUD plus scheduling queries over the persisted task list. Follows the
/// plain SharedPreferences style of [UsageStatsStore]; the clock is
/// injectable so tests can drive due-ness deterministically.
class ScheduledTaskStore {
  ScheduledTaskStore(this._prefs, {DateTime Function()? clock})
      : _clock = clock;

  final SharedPreferences _prefs;
  final DateTime Function()? _clock;

  static const _tasksKey = 'shelly.sched.tasks';
  static int _idSeed = 0;

  /// Current time; tests inject a fixed clock here.
  DateTime now() => _clock?.call() ?? DateTime.now();

  /// All tasks, earliest schedule first.
  List<ScheduledTask> loadTasks() {
    final raw = _prefs.getString(_tasksKey);
    if (raw == null) return const [];
    try {
      final tasks = [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry is Map<String, dynamic>) ScheduledTask.fromJson(entry),
      ]..sort((a, b) => a.at.compareTo(b.at));
      return tasks;
    } on FormatException {
      return const [];
    }
  }

  ScheduledTask? taskById(String id) {
    for (final task in loadTasks()) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// Cheap guard for the shell ticker: true while any task is enabled.
  bool hasEnabledTasks() {
    for (final task in loadTasks()) {
      if (task.enabled) return true;
    }
    return false;
  }

  /// True while any enabled task still has a run ahead of it: repeating
  /// tasks always, one-shot tasks until they complete (or fail terminally).
  /// The shell ticker holds its periodic timer exactly this long.
  bool hasRunnableTasks() {
    for (final task in loadTasks()) {
      if (task.enabled &&
          (task.repeat != TaskRepeatMode.once ||
              task.status == ScheduledTaskStatus.pending)) {
        return true;
      }
    }
    return false;
  }

  /// Enabled tasks whose schedule has come due at [at].
  List<ScheduledTask> dueTasks(DateTime at) =>
      [for (final task in loadTasks()) if (task.isDue(at)) task];

  Future<ScheduledTask> addTask({
    required String prompt,
    required DateTime at,
    TaskRepeatMode repeat = TaskRepeatMode.once,
    bool enabled = true,
  }) async {
    _idSeed += 1;
    final task = ScheduledTask(
      id:
          'sched-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$_idSeed',
      prompt: prompt,
      at: at,
      repeat: repeat,
      enabled: enabled,
    );
    await _save([...loadTasks(), task]);
    return task;
  }

  /// Upserts [task] by id.
  Future<void> saveTask(ScheduledTask task) async {
    final tasks = loadTasks();
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index < 0) {
      await _save([...tasks, task]);
    } else {
      tasks[index] = task;
      await _save(tasks);
    }
  }

  Future<void> removeTask(String id) async =>
      _save([...loadTasks().where((task) => task.id != id)]);

  Future<void> setEnabled(String id, bool enabled) async {
    final tasks = loadTasks();
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) return;
    tasks[index] = tasks[index].copyWith(enabled: enabled);
    await _save(tasks);
  }

  /// Records one run's outcome and reschedules the task. One-shot tasks
  /// keep their schedule and become terminal ([ScheduledTaskStatus.done] or
  /// [ScheduledTaskStatus.failed]); repeating tasks move [ScheduledTask.at]
  /// to the next occurrence after the run so missed windows are never
  /// re-entered. Returns the updated record, or null when the task was
  /// deleted while it ran.
  Future<ScheduledTask?> recordRun(
    String id, {
    required String result,
    required bool success,
    DateTime? ranAt,
  }) async {
    final tasks = loadTasks();
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) return null;
    final stamp = ranAt ?? now();
    final task = tasks[index];
    tasks[index] = ScheduledTask(
      id: task.id,
      prompt: task.prompt,
      at: task.repeat == TaskRepeatMode.once
          ? task.at
          : task.nextOccurrenceAfter(stamp),
      repeat: task.repeat,
      enabled: task.enabled,
      lastRunAt: stamp,
      result: result,
      status: success ? ScheduledTaskStatus.done : ScheduledTaskStatus.failed,
    );
    await _save(tasks);
    return tasks[index];
  }

  Future<void> _save(List<ScheduledTask> tasks) => _prefs.setString(
        _tasksKey,
        jsonEncode([for (final task in tasks) task.toJson()]),
      );
}

/// Headless execution callback: runs one task's prompt and returns the
/// model reply text. Throwing marks the run as failed.
typedef ScheduledTaskRunner = Future<String> Function(ScheduledTask task);

/// Thrown by the built-in runner when no model endpoint is configured; the
/// message becomes the task's stored result.
class ScheduledTaskException implements Exception {
  const ScheduledTaskException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the production runner: one non-streaming completion through the
/// app's OpenAI-compatible gateway, opened by the active agent profile's
/// persona as the system message (mirroring the chat path's fresh-task
/// prompt). The gateway is rebuilt per run so model changes apply to the
/// next task without a restart. [transport] is for tests only.
ScheduledTaskRunner settingsBackedRunner(
  SettingsStore store, {
  ChatTransport? transport,
}) {
  return (task) async {
    final config = store.loadModelConfig();
    if (!config.isComplete) {
      throw const ScheduledTaskException('模型端点未配置,定时任务无法执行');
    }
    final persona = store.activeProfile().systemPrompt.trim();
    final gateway = OpenAiCompatibleGateway(
      baseUrl: config.baseUrl,
      apiKey: config.apiKey,
      model: config.model,
      transport: transport,
    );
    final reply = await gateway.complete([
      if (persona.isNotEmpty)
        AgentMessage(role: MessageRole.system, content: persona),
      AgentMessage(role: MessageRole.user, content: task.prompt),
    ]);
    return reply.content;
  };
}

/// Finds and executes due scheduled tasks (PHASE 41). Runs in-app only: a
/// tick is triggered by the shell's timer or app resume, never by OS
/// background machinery. Every failure is recorded on the task itself —
/// [tick] never throws.
class SchedulerService {
  SchedulerService({
    required this.store,
    this.runner,
    DateTime Function()? clock,
  }) : _clock = clock;

  final ScheduledTaskStore store;

  /// Null when no execution path is available: due tasks simply stay
  /// pending until the next tick after a runner appears.
  final ScheduledTaskRunner? runner;
  final DateTime Function()? _clock;

  bool _ticking = false;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  /// Runs every due enabled task once, stores the result and reschedules.
  /// Returns the updated records for the tasks that ran; an empty list when
  /// nothing was due (the cheap path the periodic timer mostly hits).
  Future<List<ScheduledTask>> tick() async {
    if (_ticking) return const [];
    final now = _now();
    final due = store.dueTasks(now);
    if (due.isEmpty) return const [];
    final run = runner;
    if (run == null) return const [];

    _ticking = true;
    final ran = <ScheduledTask>[];
    try {
      for (final task in due) {
        // Re-check: the task may have been edited, disabled or deleted
        // while earlier tasks in this batch were running.
        final current = store.taskById(task.id);
        if (current == null || !current.isDue(now)) continue;
        String result;
        var success = false;
        try {
          result = await run(current);
          success = true;
        } catch (error) {
          result = '执行失败:$error';
        }
        try {
          final updated = await store.recordRun(
            current.id,
            result: result,
            success: success,
            ranAt: _now(),
          );
          if (updated != null) ran.add(updated);
        } catch (_) {
          // Persisting the outcome is best-effort; move on to the next task.
        }
      }
    } finally {
      _ticking = false;
    }
    return ran;
  }
}

/// Interval between automatic ticks; overridable so tests can shrink it.
Duration schedulerTickInterval = const Duration(seconds: 60);

/// Arms [SchedulerService.tick] from the app shell. The periodic timer only
/// runs while some task still has a run ahead of it — an app with nothing
/// scheduled holds no timers at all — and each tick re-evaluates, so the
/// loop stops itself once the last task completes, is disabled or deleted.
class SchedulerTicker {
  SchedulerTicker(this._service);

  final SchedulerService _service;
  Timer? _timer;

  /// True while the periodic tick loop is armed.
  bool get isRunning => _timer != null;

  /// Arms the tick loop while any task still has a run ahead of it; a
  /// no-op otherwise. Called on shell init and whenever the tasks page
  /// changes the store.
  void ensureRunning() {
    _syncBackgroundState();
    if (_timer != null) return;
    if (!_service.store.hasRunnableTasks()) return;
    _timer = Timer.periodic(schedulerTickInterval, (_) => tick());
  }

  /// Mirrors the runnable schedule into native prefs and (re)arms the
  /// native 15-minute periodic check, so the WorkManager worker (PHASE 45)
  /// can wake the user for due tasks after the app was swiped away.
  /// Best-effort on all hosts.
  void _syncBackgroundState() {
    try {
      final bridge = _backgroundBridge ??= BackgroundTaskBridge();
      unawaited(bridge.scheduleWorkChecks(intervalMinutes: 15));
      final mirrors = <Map<String, dynamic>>[];
      for (final task in _service.store.loadTasks()) {
        final runnable = task.enabled &&
            (task.repeat != TaskRepeatMode.once ||
                task.status == ScheduledTaskStatus.pending);
        if (runnable) {
          mirrors.add({
            'id': task.id,
            'at': task.at.millisecondsSinceEpoch,
          });
        }
      }
      unawaited(bridge.pushState(mirrors));
    } catch (_) {
      // Background wake-ups are an enhancement, never a requirement.
    }
  }

  static BackgroundTaskBridge? _backgroundBridge;

  /// Stops the loop. Safe to call repeatedly.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One scheduling pass. Never throws; the loop stops itself once no
  /// enabled task remains.
  Future<void> tick() async {
    try {
      await _service.tick();
    } catch (_) {
      // The service guards its own runs; this keeps any stray error from
      // ever reaching the shell.
    } finally {
      if (!_service.store.hasRunnableTasks()) stop();
    }
  }

  /// The tasks page created, toggled or deleted a task: re-arm if needed.
  void onStoreChanged() => ensureRunning();

  /// App came back to the foreground: re-arm and run an immediate catch-up
  /// tick so schedules missed while the app was closed run once, now.
  Future<void> onResume() async {
    ensureRunning();
    await tick();
  }

  void dispose() => stop();
}

/// Reactive store access for the tasks page.
final scheduledTaskStoreProvider = FutureProvider<ScheduledTaskStore>(
  (ref) async => ScheduledTaskStore(await SharedPreferences.getInstance()),
);

/// The scheduler wired to the app's model settings; the shell resolves this
/// once to build its ticker.
final schedulerServiceProvider = FutureProvider<SchedulerService>((ref) async {
  final store = await ref.watch(scheduledTaskStoreProvider.future);
  final settings = await ref.watch(settingsStoreProvider.future);
  return SchedulerService(store: store, runner: settingsBackedRunner(settings));
});

/// Bumped by the tasks page after every store mutation so the page list
/// reloads and the shell ticker re-arms.
final scheduledTasksRevisionProvider = StateProvider<int>((ref) => 0);
