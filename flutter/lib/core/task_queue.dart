// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'agent_core.dart';
import 'models.dart';

/// Task lifecycle states, ported from Kotlin `AgentCoreAndroidCoordinator`
/// and extended (PHASE 21) with the unified runtime states:
/// - `queued`: accepted but waiting for a concurrency slot
/// - `waitingTool`: a tool call is awaiting user approval
/// - `paused`: a queued task parked by the user; resumable
/// - `recovering`: restarting from a checkpoint before running
/// UI maps these onto progress, cancel affordances and completion badges.
enum TaskState {
  queued,
  paused,
  recovering,
  starting,
  running,
  waitingTool,
  stopping,
  cancelling,
  completed,
  stopped,
  failed,
}

class TaskStatus {
  const TaskStatus({required this.taskId, required this.state, this.error});

  final String taskId;
  final TaskState state;

  /// Set when [TaskState.failed].
  final Object? error;

  @override
  String toString() => 'TaskStatus($taskId, ${state.name}${error == null ? '' : ', error: $error'})';
}

/// Host-implemented runner: executes one task to completion, honoring the
/// [cancellation] signal. Returns the final [AgentResult].
abstract interface class AgentTaskRunner {
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  });
}

/// Optional runner capability (PHASE 21): lets the coordinator observe
/// in-task lifecycle events so approvals surface as a task state
/// (`waitingTool`) instead of living only in the UI layer.
abstract interface class AgentEventReporter {
  set eventObserver(AgentObserver? observer);
}

/// Coordinates multiple concurrent agent tasks. Deliberately free of Flutter
/// and platform imports so it runs in `dart test` exactly as it will on
/// Android; the UI layer subscribes via [listener].
class TaskCoordinator {
  TaskCoordinator({
    required AgentTaskRunner Function(String taskId) agentFactory,
    required void Function(TaskStatus status) listener,
    this.maxConcurrent,
  })  : _agentFactory = agentFactory,
        _listener = listener;

  /// Upper bound on simultaneously running tasks; null means unlimited.
  /// [enqueue] waits for a slot, [start] always runs immediately.
  final int? maxConcurrent;

  final AgentTaskRunner Function(String taskId) _agentFactory;
  final void Function(TaskStatus status) _listener;
  final Map<String, _RunningTask> _tasks = {};
  final List<_PendingTask> _pending = [];
  final List<_PendingTask> _paused = [];

  /// Starts a task once. Returns false when the same task id is already
  /// active, queued or parked.
  bool start(String taskId, List<AgentMessage> messages, {AgentCheckpoint? resumeFrom}) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be blank');
    }
    if (_tasks.containsKey(taskId) || _holds(taskId)) return false;
    _launch(taskId, messages, resumeFrom: resumeFrom);
    return true;
  }

  /// Accepts a task into the unified queue (PHASE 21). It starts as soon as
  /// a concurrency slot is free; a checkpoint turns the start into a
  /// `recovering` transition.
  bool enqueue(String taskId, List<AgentMessage> messages, {AgentCheckpoint? resumeFrom}) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be blank');
    }
    if (_tasks.containsKey(taskId) || _holds(taskId)) return false;
    _pending.add(_PendingTask(
      taskId: taskId,
      messages: messages,
      resumeFrom: resumeFrom,
    ));
    _publish(taskId, TaskState.queued);
    _drain();
    return true;
  }

  /// Parks a queued (not yet running) task. Running tasks keep going.
  bool pause(String taskId) {
    final index = _pending.indexWhere((p) => p.taskId == taskId);
    if (index < 0) return false;
    _paused.add(_pending.removeAt(index));
    _publish(taskId, TaskState.paused);
    return true;
  }

  /// Returns a parked task to the queue.
  bool resume(String taskId) {
    final index = _paused.indexWhere((p) => p.taskId == taskId);
    if (index < 0) return false;
    _pending.add(_paused.removeAt(index));
    _publish(taskId, TaskState.queued);
    _drain();
    return true;
  }

  /// Requests a cooperative stop. AgentCore observes this through the
  /// cancellation signal carried by the running task.
  bool stop(String taskId) => _signal(taskId, TaskState.stopping);

  /// Requests user cancellation. Uses the same cooperative signal with a
  /// distinct UI state.
  bool cancel(String taskId) => _signal(taskId, TaskState.cancelling);

  /// Drops a queued or parked task without ever running it.
  bool dismiss(String taskId) {
    final beforePending = _pending.length;
    final beforePaused = _paused.length;
    _pending.removeWhere((p) => p.taskId == taskId);
    _paused.removeWhere((p) => p.taskId == taskId);
    if (_pending.length == beforePending && _paused.length == beforePaused) {
      return false;
    }
    _tasks[taskId] = _RunningTask(taskId)..state = TaskState.stopped;
    _listener(TaskStatus(taskId: taskId, state: TaskState.stopped));
    _tasks.remove(taskId);
    _drain();
    return true;
  }

  TaskState? state(String taskId) =>
      _tasks[taskId]?.state ?? _pendingStateOf(taskId);

  TaskState? _pendingStateOf(String taskId) {
    if (_pending.any((p) => p.taskId == taskId)) return TaskState.queued;
    if (_paused.any((p) => p.taskId == taskId)) return TaskState.paused;
    return null;
  }

  Set<String> activeTaskIds() => Set.of(_tasks.keys);

  /// Task ids accepted but not yet running (queued and parked).
  List<String> pendingTaskIds() => [
        for (final p in _pending.followedBy(_paused)) p.taskId,
      ];

  bool _holds(String taskId) =>
      _pending.any((p) => p.taskId == taskId) ||
      _paused.any((p) => p.taskId == taskId);

  void _drain() {
    while (_pending.isNotEmpty &&
        (maxConcurrent == null || _tasks.length < maxConcurrent!)) {
      final pending = _pending.removeAt(0);
      _launch(pending.taskId, pending.messages, resumeFrom: pending.resumeFrom);
    }
  }

  void _launch(String taskId, List<AgentMessage> messages,
      {AgentCheckpoint? resumeFrom}) {
    final task = _RunningTask(taskId);
    _tasks[taskId] = task;

    // A checkpoint resume reports `recovering` before the usual start.
    _publish(taskId,
        resumeFrom != null ? TaskState.recovering : TaskState.starting);

    // Wire in-task event reporting when the runner supports it, so approval
    // waits surface as the unified `waitingTool` state.
    final runner = _agentFactory(taskId);
    if (runner case AgentEventReporter reporter) {
      reporter.eventObserver = _EventBridge(task, _publish);
    }

    unawaited(() async {
      _publish(taskId, task.cancelled ? task.state : TaskState.running);
      try {
        final result = await runner.run(messages, task, resumeFrom: resumeFrom);
        _finish(task, result);
      } catch (error) {
        _fail(task, error);
      }
    }());
  }

  void _publish(String taskId, TaskState state) {
    final task = _tasks[taskId];
    if (task != null) task.state = state;
    _listener(TaskStatus(taskId: taskId, state: state));
  }

  bool _signal(String taskId, TaskState state) {
    final task = _tasks[taskId];
    if (task == null) return false;
    if (task.cancelled) return false;
    task.cancelled = true;
    _publish(taskId, state);
    return true;
  }

  void _finish(_RunningTask task, AgentResult result) {
    if (!identical(_tasks[task.taskId], task)) return;
    _tasks.remove(task.taskId);
    final finalState =
        result is AgentCompleted ? TaskState.completed : TaskState.stopped;
    task.state = finalState;
    _listener(TaskStatus(taskId: task.taskId, state: finalState));
    _drain();
  }

  void _fail(_RunningTask task, Object error) {
    if (!identical(_tasks[task.taskId], task)) return;
    _tasks.remove(task.taskId);
    task.state = TaskState.failed;
    _listener(TaskStatus(taskId: task.taskId, state: TaskState.failed, error: error));
    _drain();
  }
}

class _PendingTask {
  _PendingTask({
    required this.taskId,
    required this.messages,
    this.resumeFrom,
  });

  final String taskId;
  final List<AgentMessage> messages;
  final AgentCheckpoint? resumeFrom;
}

/// Forwards only the approval lifecycle into task states; model/tool
/// progress stays with the conversation observer.
class _EventBridge implements AgentObserver {
  _EventBridge(this._task, this._publish);

  final _RunningTask _task;
  final void Function(String taskId, TaskState state) _publish;

  @override
  void onEvent(AgentEvent event) {
    if (_task.cancelled) return;
    if (event is ApprovalWaiting) {
      _publish(_task.taskId, TaskState.waitingTool);
    } else if (event is ApprovalFinished) {
      _publish(_task.taskId, TaskState.running);
    }
  }
}

class _RunningTask implements CancellationSignal {
  _RunningTask(this.taskId);

  final String taskId;
  bool cancelled = false;
  TaskState state = TaskState.starting;

  @override
  bool get isCancelled => cancelled;
}
