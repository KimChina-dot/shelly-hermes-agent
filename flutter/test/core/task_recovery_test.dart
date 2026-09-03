import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/task_recovery.dart';
import 'package:shelly_hermes/state/settings_store.dart';

class _FakeRecoveryStore implements TaskRecoveryStore {
  TaskRecoveryRecord? record;
  final Map<String, AgentCheckpoint> checkpoints = {};

  @override
  TaskRecoveryRecord? loadActiveTask() => record;

  @override
  Future<void> saveActiveTask(TaskRecoveryRecord value) async => record = value;

  @override
  Future<void> clearActiveTask() async => record = null;

  @override
  AgentCheckpoint? loadCheckpoint(String conversationId) =>
      checkpoints[conversationId];
}

const _checkpoint = AgentCheckpoint(
  messages: [AgentMessage(role: MessageRole.user, content: '任务')],
  round: 3,
  consumedTokens: 24,
  toolCalls: 2,
);

void main() {
  test('scan returns a candidate only with both record and checkpoint',
      () async {
    const recovery = TaskRecovery();
    final store = _FakeRecoveryStore();

    // Clean previous run — nothing to recover.
    expect(recovery.scan(store), isEmpty);

    // A record without a checkpoint offers nothing safe to resume.
    await store.saveActiveTask(TaskRecoveryRecord(
      conversationId: 'c1',
      taskId: 'task-1',
      startedAt: DateTime.now(),
    ));
    expect(recovery.scan(store), isEmpty);

    // Record + checkpoint: the task died with the process and is resumable.
    store.checkpoints['c1'] = _checkpoint;
    final candidates = recovery.scan(store);
    expect(candidates, hasLength(1));
    expect(candidates.single.record.taskId, 'task-1');
    expect(candidates.single.checkpoint.round, 3);
  });
  test('record json round trip tolerates corrupt input', () {
    final record = TaskRecoveryRecord(
      conversationId: 'c1',
      taskId: 'task-9',
      startedAt: DateTime.parse('2026-01-02T03:04:05.000'),
    );
    final restored = TaskRecoveryRecord.decode(record.encode());
    expect(restored.conversationId, 'c1');
    expect(restored.taskId, 'task-9');
    expect(restored.startedAt, record.startedAt);

    expect(
        TaskRecoveryRecord.fromJson(const {
          'conversationId': 'c2',
        }).startedAt,
        DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('settings store persists and clears the active-task record',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());

    expect(store.loadActiveTask(), isNull);

    final record = TaskRecoveryRecord(
      conversationId: 'conv-1',
      taskId: 'task-42',
      startedAt: DateTime.parse('2026-02-03T04:05:06.000'),
    );
    await store.saveActiveTask(record);
    expect(store.loadActiveTask()?.conversationId, 'conv-1');
    expect(store.loadActiveTask()?.taskId, 'task-42');

    await store.clearActiveTask();
    expect(store.loadActiveTask(), isNull);
  });
}
