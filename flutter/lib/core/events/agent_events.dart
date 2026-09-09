/// Domain-level, mission-scoped events for the v3 agent engine.
///
/// Parallel to the round-level `AgentEvent` family in
/// `lib/core/models.dart` and intentionally *not* extending it: agent
/// rounds are engine internals while missions are user-facing,
/// long-running work. Every timestamp is passed in by the caller at
/// construction time — no internal clock — so events stay fully
/// reproducible in tests and replays.
sealed class MissionEvent {
  const MissionEvent();

  /// Identifier of the mission this event belongs to. Every mission
  /// event is mission-scoped, so this is available on the shared base.
  String get missionId;
}

/// Emitted when a new mission is created.
class MissionCreated extends MissionEvent {
  const MissionCreated({
    required this.missionId,
    required this.title,
    required this.at,
  });

  @override
  final String missionId;
  final String title;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is MissionCreated &&
      other.missionId == missionId &&
      other.title == title &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, title, at);

  @override
  String toString() =>
      'MissionCreated(missionId: $missionId, title: $title, at: $at)';
}

/// Emitted when an execution plan for a mission is first produced.
class PlanCreated extends MissionEvent {
  const PlanCreated({
    required this.missionId,
    required this.steps,
    required this.at,
  });

  @override
  final String missionId;
  final List<String> steps;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is PlanCreated &&
      other.missionId == missionId &&
      _listEquals(other.steps, steps) &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, Object.hashAll(steps), at);

  @override
  String toString() =>
      'PlanCreated(missionId: $missionId, steps: ${steps.length}, at: $at)';
}

/// Emitted when an existing plan is revised (replanning, insertion, …).
class PlanUpdated extends MissionEvent {
  const PlanUpdated({
    required this.missionId,
    required this.steps,
    required this.at,
  });

  @override
  final String missionId;
  final List<String> steps;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is PlanUpdated &&
      other.missionId == missionId &&
      _listEquals(other.steps, steps) &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, Object.hashAll(steps), at);

  @override
  String toString() =>
      'PlanUpdated(missionId: $missionId, steps: ${steps.length}, at: $at)';
}

/// Emitted when a task inside a mission starts executing.
class TaskStarted extends MissionEvent {
  const TaskStarted({
    required this.missionId,
    required this.taskId,
    required this.title,
    required this.at,
  });

  @override
  final String missionId;
  final String taskId;
  final String title;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is TaskStarted &&
      other.missionId == missionId &&
      other.taskId == taskId &&
      other.title == title &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, taskId, title, at);

  @override
  String toString() =>
      'TaskStarted(missionId: $missionId, taskId: $taskId, title: $title, '
      'at: $at)';
}

/// Emitted when a task inside a mission finishes successfully.
class TaskCompleted extends MissionEvent {
  const TaskCompleted({
    required this.missionId,
    required this.taskId,
    required this.at,
  });

  @override
  final String missionId;
  final String taskId;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is TaskCompleted &&
      other.missionId == missionId &&
      other.taskId == taskId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, taskId, at);

  @override
  String toString() =>
      'TaskCompleted(missionId: $missionId, taskId: $taskId, at: $at)';
}

/// Emitted when a task inside a mission fails.
class TaskFailed extends MissionEvent {
  const TaskFailed({
    required this.missionId,
    required this.taskId,
    required this.error,
    required this.at,
  });

  @override
  final String missionId;
  final String taskId;
  final String error;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is TaskFailed &&
      other.missionId == missionId &&
      other.taskId == taskId &&
      other.error == error &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, taskId, error, at);

  @override
  String toString() =>
      'TaskFailed(missionId: $missionId, taskId: $taskId, error: $error, '
      'at: $at)';
}

/// Emitted when an individual step of a task starts executing.
class StepStarted extends MissionEvent {
  const StepStarted({
    required this.missionId,
    required this.taskId,
    required this.stepIndex,
    required this.at,
  });

  @override
  final String missionId;
  final String taskId;
  final int stepIndex;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is StepStarted &&
      other.missionId == missionId &&
      other.taskId == taskId &&
      other.stepIndex == stepIndex &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, taskId, stepIndex, at);

  @override
  String toString() =>
      'StepStarted(missionId: $missionId, taskId: $taskId, '
      'stepIndex: $stepIndex, at: $at)';
}

/// Emitted when the whole mission finishes successfully.
class MissionCompleted extends MissionEvent {
  const MissionCompleted({required this.missionId, required this.at});

  @override
  final String missionId;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is MissionCompleted &&
      other.missionId == missionId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, at);

  @override
  String toString() => 'MissionCompleted(missionId: $missionId, at: $at)';
}

/// Emitted when the whole mission aborts with a failure.
class MissionFailed extends MissionEvent {
  const MissionFailed({
    required this.missionId,
    required this.error,
    required this.at,
  });

  @override
  final String missionId;
  final String error;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is MissionFailed &&
      other.missionId == missionId &&
      other.error == error &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, error, at);

  @override
  String toString() =>
      'MissionFailed(missionId: $missionId, error: $error, at: $at)';
}

/// Emitted when a mission is cancelled by the user or the system.
class MissionCancelled extends MissionEvent {
  const MissionCancelled({required this.missionId, required this.at});

  @override
  final String missionId;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is MissionCancelled &&
      other.missionId == missionId &&
      other.at == at;

  @override
  int get hashCode => Object.hash(missionId, at);

  @override
  String toString() => 'MissionCancelled(missionId: $missionId, at: $at)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
