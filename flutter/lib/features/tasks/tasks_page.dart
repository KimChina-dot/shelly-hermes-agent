import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/task_queue.dart';
import '../../design/components/empty_state.dart';
import '../../design/tokens.dart';
import '../../state/chat_session.dart';
import '../../state/scheduled_tasks.dart';

/// Task queue page: live status of the conversation task plus the rolling
/// status log, and (PHASE 41) the in-app scheduled agent tasks. Each
/// running task can be cancelled; scheduled tasks support create, edit,
/// enable, delete and an expandable last-result view.
class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});

  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  /// Id of the scheduled task whose last result is expanded, if any.
  String? _expandedTaskId;

  ScheduledTaskStore? get _store =>
      ref.read(scheduledTaskStoreProvider).value;

  void _bumpRevision() {
    ref.read(scheduledTasksRevisionProvider.notifier).state += 1;
  }

  Future<void> _openTaskDialog(ScheduledTask? task) async {
    final store = _store;
    if (store == null) return;
    final draft = await showDialog<_ScheduledTaskDraft>(
      context: context,
      builder: (_) => _ScheduledTaskDialog(existing: task),
    );
    if (draft == null || !mounted) return;
    if (task == null) {
      await store.addTask(
        prompt: draft.prompt,
        at: draft.at,
        repeat: draft.repeat,
        enabled: draft.enabled,
      );
    } else {
      // Editing rebuilds the schedule: run bookkeeping starts fresh.
      await store.saveTask(ScheduledTask(
        id: task.id,
        prompt: draft.prompt,
        at: draft.at,
        repeat: draft.repeat,
        enabled: draft.enabled,
      ));
    }
    _bumpRevision();
  }

  Future<void> _toggleEnabled(ScheduledTask task, bool enabled) async {
    final store = _store;
    if (store == null) return;
    await store.setEnabled(task.id, enabled);
    _bumpRevision();
  }

  Future<void> _deleteTask(ScheduledTask task) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除定时任务'),
        content: Text(
          task.prompt,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.removeTask(task.id);
    if (_expandedTaskId == task.id) {
      setState(() => _expandedTaskId = null);
    }
    _bumpRevision();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final session = ref.watch(chatSessionProvider);
    final history = ref.watch(taskHistoryProvider);
    // Watching the revision reloads the schedule after every mutation; the
    // store provider is watched too so the first load re-renders.
    ref.watch(scheduledTasksRevisionProvider);
    final scheduled =
        ref.watch(scheduledTaskStoreProvider).value?.loadTasks() ??
            const <ScheduledTask>[];

    final idle = session.activeTaskId == null &&
        history.isEmpty &&
        scheduled.isEmpty;

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
      body: idle
          ? EmptyState(
              icon: Icons.account_tree_outlined,
              title: '暂无任务',
              body: '在对话页发起请求后,任务状态会实时显示在这里;也可以创建定时任务,'
                  '让 Shelly 到点自动执行。',
              actionLabel: '新建定时任务',
              onAction: () => _openTaskDialog(null),
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
                _SectionHeader(
                  title: '定时任务',
                  onAdd: () => _openTaskDialog(null),
                ),
                if (scheduled.isEmpty)
                  _HintCard(
                    text: '还没有定时任务。点右上角 + 新建,支持每天/每周重复,'
                        '到点由应用自动执行。',
                  )
                else
                  ...scheduled.map(
                    (task) => _ScheduledTaskCard(
                      task: task,
                      expanded: _expandedTaskId == task.id,
                      onToggleExpanded: () => setState(() {
                        _expandedTaskId =
                            _expandedTaskId == task.id ? null : task.id;
                      }),
                      onToggleEnabled: (value) =>
                          _toggleEnabled(task, value),
                      onEdit: () => _openTaskDialog(task),
                      onDelete: () => _deleteTask(task),
                    ),
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

/// Section title row with a trailing add affordance.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onAdd});

  final String title;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding: const EdgeInsets.only(
          top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: semantic.textTertiary)),
          const Spacer(),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              onPressed: onAdd,
              tooltip: '新建定时任务',
              padding: EdgeInsets.zero,
              iconSize: 20,
              icon: Icon(Icons.add_rounded,
                  color: semantic.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line hint shown in place of the schedule list.
class _HintCard extends StatelessWidget {
  const _HintCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12.5, color: semantic.textSecondary)),
    );
  }
}

class _ScheduledTaskCard extends StatelessWidget {
  const _ScheduledTaskCard({
    required this.task,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onDelete,
  });

  final ScheduledTask task;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static const _repeatMeta = <TaskRepeatMode, (Color, String, IconData)>{
    TaskRepeatMode.once: (AppColors.brandBlue, '单次', Icons.schedule_outlined),
    TaskRepeatMode.daily: (AppColors.success, '每天', Icons.today_outlined),
    TaskRepeatMode.weekly:
        (AppColors.brandViolet, '每周', Icons.date_range_outlined),
  };

  String get _nextRunLabel {
    final now = DateTime.now();
    if (task.enabled && task.at.isBefore(now)) return '等待补跑';
    final time =
        '${task.at.hour.toString().padLeft(2, '0')}:${task.at.minute.toString().padLeft(2, '0')}';
    final diff = DateTime(task.at.year, task.at.month, task.at.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    if (diff == 0) return '今天 $time';
    if (diff == 1) return '明天 $time';
    return '${task.at.month}月${task.at.day}日 $time';
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final (badgeColor, badgeLabel, icon) = _repeatMeta[task.repeat]!;
    final accent = task.enabled ? badgeColor : semantic.textTertiary;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: badgeColor
                      .withValues(alpha: task.enabled ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, size: 19, color: accent),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: task.enabled
                              ? semantic.textPrimary
                              : semantic.textTertiary),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(_nextRunLabel,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: semantic.textSecondary)),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.14),
                            borderRadius:
                                BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(badgeLabel,
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: task.enabled
                                      ? badgeColor
                                      : semantic.textTertiary)),
                        ),
                        if (task.lastRunAt != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Icon(
                            task.status == ScheduledTaskStatus.failed
                                ? Icons.error_outline
                                : Icons.check_circle_outline,
                            size: 14,
                            color: task.status ==
                                    ScheduledTaskStatus.failed
                                ? AppColors.danger
                                : AppColors.success,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                height: 32,
                child: Switch(
                  value: task.enabled,
                  onChanged: onToggleEnabled,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              _CardAction(label: '编辑', onTap: onEdit),
              _CardAction(label: '删除', danger: true, onTap: onDelete),
              if (task.result != null)
                _CardAction(
                  label: expanded ? '收起结果' : '查看结果',
                  icon: expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  onTap: onToggleExpanded,
                ),
            ],
          ),
          if (expanded && task.result != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: AppSpacing.xs),
              padding: const EdgeInsets.all(AppSpacing.sm + 2),
              decoration: BoxDecoration(
                color: semantic.background,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: semantic.border),
              ),
              child: Text(
                task.result!,
                style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: semantic.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact text action used under each scheduled task card.
class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: 14,
                color: danger ? AppColors.danger : semantic.textSecondary),
            const SizedBox(width: 2),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: danger ? AppColors.danger : semantic.textSecondary)),
        ],
      ),
    );
  }
}

/// What the edit dialog hands back on save.
class _ScheduledTaskDraft {
  const _ScheduledTaskDraft({
    required this.prompt,
    required this.at,
    required this.repeat,
    required this.enabled,
  });

  final String prompt;
  final DateTime at;
  final TaskRepeatMode repeat;
  final bool enabled;
}

class _ScheduledTaskDialog extends StatefulWidget {
  const _ScheduledTaskDialog({this.existing});

  final ScheduledTask? existing;

  @override
  State<_ScheduledTaskDialog> createState() => _ScheduledTaskDialogState();
}

class _ScheduledTaskDialogState extends State<_ScheduledTaskDialog> {
  late final TextEditingController _prompt;
  late DateTime _at;
  late TaskRepeatMode _repeat;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
    _at = widget.existing?.at ??
        DateTime(now.year, now.month, now.day, now.hour, now.minute)
            .add(const Duration(hours: 1));
    _repeat = widget.existing?.repeat ?? TaskRepeatMode.once;
    _enabled = widget.existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  static String _repeatLabel(TaskRepeatMode mode) => switch (mode) {
        TaskRepeatMode.once => '单次',
        TaskRepeatMode.daily => '每天',
        TaskRepeatMode.weekly => '每周',
      };

  String get _scheduleLabel {
    final time =
        '${_at.hour.toString().padLeft(2, '0')}:${_at.minute.toString().padLeft(2, '0')}';
    return '${_at.year}年${_at.month}月${_at.day}日 $time';
  }

  Future<void> _pickSchedule() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (!mounted) return;
    setState(() {
      _at = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? _at.hour,
        time?.minute ?? _at.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final valid = _prompt.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.existing == null ? '新建定时任务' : '编辑定时任务'),
      contentPadding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _prompt,
                maxLines: 4,
                minLines: 2,
                maxLength: 2000,
                autofocus: widget.existing == null,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14, height: 1.5),
                decoration: const InputDecoration(
                  hintText: '到点要让 Shelly 做什么?例如:总结今天的待办并生成清单',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton.icon(
                onPressed: _pickSchedule,
                icon: const Icon(Icons.event_outlined, size: 18),
                label: Text(_scheduleLabel,
                    style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final mode in TaskRepeatMode.values)
                    ChoiceChip(
                      label: Text(_repeatLabel(mode),
                          style: const TextStyle(fontSize: 12)),
                      selected: _repeat == mode,
                      onSelected: (_) => setState(() => _repeat = mode),
                    ),
                ],
              ),
              SwitchListTile(
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('启用', style: TextStyle(fontSize: 14)),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: valid
              ? () => Navigator.pop(
                  context,
                  _ScheduledTaskDraft(
                    prompt: _prompt.text.trim(),
                    at: _at,
                    repeat: _repeat,
                    enabled: _enabled,
                  ))
              : null,
          child: const Text('保存'),
        ),
      ],
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
      TaskState.queued => (
          semantic.textTertiary,
          '排队中',
          Icons.schedule_outlined
        ),
      TaskState.paused => (
          AppColors.warning,
          '已暂停',
          Icons.pause_circle_outline
        ),
      TaskState.recovering => (
          AppColors.brandBlue,
          '恢复中',
          Icons.restore_outlined
        ),
      TaskState.waitingTool => (
          AppColors.warning,
          '等待确认',
          Icons.touch_app_outlined
        ),
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
