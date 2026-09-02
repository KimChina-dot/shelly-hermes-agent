import 'dart:convert';

import 'models.dart';

/// Background agent recovery (V2.0 PHASE 20). While a task runs the host
/// persists a small record plus the rolling checkpoint. If the OS kills the
/// process, the next launch finds the record without a completion marker —
/// that task died with the process and can resume from its checkpoint
/// through the unified runtime's `recovering` state.
///
/// Pure logic + a persistence port, so it runs in `dart test` exactly as it
/// will on Android.
class TaskRecoveryRecord {
  const TaskRecoveryRecord({
    required this.conversationId,
    required this.taskId,
    required this.startedAt,
  });

  final String conversationId;
  final String taskId;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'taskId': taskId,
        'startedAt': startedAt.toIso8601String(),
      };

  static TaskRecoveryRecord fromJson(Map<String, dynamic> json) =>
      TaskRecoveryRecord(
        conversationId: json['conversationId'] as String? ?? '',
        taskId: json['taskId'] as String? ?? '',
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );

  String encode() => jsonEncode(toJson());

  static TaskRecoveryRecord decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// One task the recovery scan found resumable.
class RecoveryCandidate {
  const RecoveryCandidate({required this.record, required this.checkpoint});

  final TaskRecoveryRecord record;
  final AgentCheckpoint checkpoint;
}

abstract interface class TaskRecoveryStore {
  /// The record of the task that was running when the app last went away,
  /// or null when the previous run ended cleanly.
  TaskRecoveryRecord? loadActiveTask();

  Future<void> saveActiveTask(TaskRecoveryRecord record);

  Future<void> clearActiveTask();

  AgentCheckpoint? loadCheckpoint(String conversationId);
}

class TaskRecovery {
  const TaskRecovery();

  /// Scans for tasks that died with the previous process. A candidate needs
  /// both the running record and a persisted checkpoint — without a
  /// checkpoint there is nothing safe to resume from.
  List<RecoveryCandidate> scan(TaskRecoveryStore store) {
    final record = store.loadActiveTask();
    if (record == null || record.conversationId.isEmpty) return const [];
    final checkpoint = store.loadCheckpoint(record.conversationId);
    if (checkpoint == null) return const [];
    return [RecoveryCandidate(record: record, checkpoint: checkpoint)];
  }
}
