// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'agent_core.dart';
import 'models.dart';

/// Task lifecycle states, ported from Kotlin `AgentCoreAndroidCoordinator`.
/// UI maps these onto progress, cancel affordances and completion badges.
enum TaskState { starting, running, stopping, cancelling, completed, stopped, failed }

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

/// Coordinates multiple concurrent agent tasks. Deliberately free of Flutter
/// and platform imports so it runs in `dart test` exactly as it will on
/// Android; the UI layer subscribes via [listener].
class TaskCoordinator {
  TaskCoordinator({
    required AgentTaskRunner Function(String taskId) agentFactory,
    required void Function(TaskStatus status) listener,
  })  : _agentFactory = agentFactory,
        _listener = listener;

  final AgentTaskRunner Function(String taskId) _agentFactory;
  final void Function(TaskStatus status) _listener;
  final Map<String, _RunningTask> _tasks = {};

  /// Starts a task once. Returns false when the same task id is already active.
  bool start(String taskId, List<AgentMessage> messages, {AgentCheckpoint? resumeFrom}) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be blank');
    }
    final task = _RunningTask(taskId);
    if (_tasks.containsKey(taskId)) return false;
    _tasks[taskId] = task;

    _publish(taskId, TaskState.starting);
    unawaited(() async {
      _publish(taskId, task.cancelled ? task.state : TaskState.running);
      try {
        final result = await _agentFactory(taskId)
            .run(messages, task, resumeFrom: resumeFrom);
        _finish(task, result);
      } catch (error) {
        _fail(task, error);
      }
    }());
    return true;
  }

  /// Requests a cooperative stop. AgentCore observes this through the
  /// cancellation signal carried by the running task.
  bool stop(String taskId) => _signal(taskId, TaskState.stopping);

  /// Requests user cancellation. Uses the same cooperative signal with a
  /// distinct UI state.
  bool cancel(String taskId) => _signal(taskId, TaskState.cancelling);

  TaskState? state(String taskId) => _tasks[taskId]?.state;

  Set<String> activeTaskIds() => Set.of(_tasks.keys);

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
  }

  void _fail(_RunningTask task, Object error) {
    if (!identical(_tasks[task.taskId], task)) return;
    _tasks.remove(task.taskId);
    task.state = TaskState.failed;
    _listener(TaskStatus(taskId: task.taskId, state: TaskState.failed, error: error));
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
