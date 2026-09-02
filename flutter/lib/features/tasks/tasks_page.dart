import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/task_queue.dart';
import '../../design/components/empty_state.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';

/// Task queue page: live status of the conversation task plus the rolling
/// status log. Each task can be cancelled while it is running.
class TasksPage extends ConsumerWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final session = ref.watch(chatSessionProvider);
    final history = ref.watch(taskHistoryProvider);

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('任务',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
      ),
      body: session.activeTaskId == null && history.isEmpty
          ? EmptyState(
              icon: Icons.account_tree_outlined,
              title: '暂无任务',
              body: '在对话页发起请求后,任务状态会实时显示在这里。',
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                if (session.activeTaskId != null)
                  _ActiveTaskCard(
                    taskId: session.activeTaskId!,
                    waitingApproval:
                        session.phase == SessionPhase.waitingApproval,
                  ),
                if (history.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                        top: AppSpacing.md, bottom: AppSpacing.sm),
                    child: Text('状态记录',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: semantic.textTertiary)),
                  ),
                  ...history.reversed
                      .take(20)
                      .map((status) => _StatusRow(status: status)),
                ],
              ],
            ),
    );
  }
}

class _ActiveTaskCard extends ConsumerWidget {
  const _ActiveTaskCard({required this.taskId, required this.waitingApproval});

  final String taskId;
  final bool waitingApproval;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
            color: (waitingApproval ? AppColors.warning : AppColors.brandBlue)
                .withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (waitingApproval ? AppColors.warning : AppColors.brandBlue)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(
              waitingApproval
                  ? Icons.verified_user_outlined
                  : Icons.autorenew_rounded,
              size: 19,
              color:
                  waitingApproval ? AppColors.warning : AppColors.brandBlue,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('进行中的对话任务',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: semantic.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  waitingApproval ? '等待你的审批决定' : '正在执行',
                  style: TextStyle(
                      fontSize: 12, color: semantic.textSecondary),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => ref.read(chatSessionProvider.notifier).cancel(),
            child: const Text('取消',
                style: TextStyle(fontSize: 13, color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final (color, label, icon) = switch (status.state) {
      TaskState.starting => (
          AppColors.brandBlue,
          '启动中',
          Icons.play_circle_outline
        ),
      TaskState.running => (
          AppColors.brandBlue,
          '运行中',
          Icons.autorenew_rounded
        ),
      TaskState.stopping => (
          AppColors.warning,
          '停止中',
          Icons.front_hand_outlined
        ),
      TaskState.cancelling => (
          AppColors.warning,
          '取消中',
          Icons.front_hand_outlined
        ),
      TaskState.completed => (
          AppColors.success,
          '已完成',
          Icons.check_circle_outline
        ),
      TaskState.stopped => (
          semantic.textTertiary,
          '已停止',
          Icons.stop_circle_outlined
        ),
      TaskState.failed => (
          AppColors.danger,
          '失败',
          Icons.error_outline
        ),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              status.error == null
                  ? '${status.taskId} · $label'
                  : '${status.taskId} · $label:${status.error}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: semantic.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
