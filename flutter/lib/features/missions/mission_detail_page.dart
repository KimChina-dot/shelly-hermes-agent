import 'package:flutter/material.dart';

import '../../application/mission_coordinator.dart';
import '../../core/events/agent_events.dart';
import '../../design/tokens.dart';
import '../../domain/agent/mission.dart';
import 'mission_timeline_page.dart'
    show
        MissionStatusVisual,
        formatMissionTime,
        missionStatusVisuals,
        missionStepCount,
        missionToneColor;

/// Read-only detail view for one mission (PHASE 13): status summary, the
/// persisted plan steps, and the chronological action log. Receives a
/// snapshot of everything the public read surfaces reported when the user
/// opened it — no live subscription, no write affordances of any kind.
class MissionDetailPage extends StatelessWidget {
  const MissionDetailPage({
    super.key,
    required this.mission,
    required this.events,
    required this.actions,
  });

  final AgentMission mission;

  /// Bus replay buffer snapshot, for the step count.
  final List<MissionEvent> events;

  /// Chronological (oldest first) actions logged for this mission.
  final List<MissionAction> actions;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final visual = missionStatusVisuals[mission.status]!;
    final color = missionToneColor(visual.tone, semantic);
    final steps = missionStepCount(mission, events);

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        title: Text(
          mission.title.isEmpty ? '(未命名使命)' : mission.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: semantic.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _SummaryCard(
              mission: mission,
              visual: visual,
              color: color,
              steps: steps),
          _SectionLabel(label: '计划步骤'),
          if (mission.plan.isEmpty)
            _HintCard(
                text: '该使命没有持久化的计划步骤;聊天类使命的轮次只记录在'
                    '进程内事件流中。')
          else
            ...mission.plan.asMap().entries.map(
                  (entry) => _PlanStepRow(
                    index: entry.key + 1,
                    text: entry.value,
                  ),
                ),
          _SectionLabel(label: '动作记录'),
          if (actions.isEmpty)
            _HintCard(text: '暂无动作记录;动作日志只保留在当前进程内,'
                '应用重启后不再展示。')
          else
            ...actions
                .skip(actions.length > 20 ? actions.length - 20 : 0)
                .map((action) => _ActionRow(action: action)),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Text(
              '只读视图 · 数据来自使命仓库与事件流',
              style:
                  TextStyle(fontSize: 11.5, color: semantic.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status, timing and counts for the whole mission.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.mission,
    required this.visual,
    required this.color,
    required this.steps,
  });

  final AgentMission mission;
  final MissionStatusVisual visual;
  final Color color;
  final int steps;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(visual.icon, size: 18, color: color),
              const SizedBox(width: AppSpacing.sm),
              Text(visual.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color,
                  )),
              const Spacer(),
              Text('$steps 步 · ${mission.taskIds.length} 个任务',
                  style: TextStyle(
                      fontSize: 12.5, color: semantic.textSecondary)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('创建于 ${formatMissionTime(mission.createdAt)}',
              style:
                  TextStyle(fontSize: 12.5, color: semantic.textSecondary)),
          const SizedBox(height: 2),
          Text('更新于 ${formatMissionTime(mission.updatedAt)}',
              style:
                  TextStyle(fontSize: 12.5, color: semantic.textSecondary)),
        ],
      ),
    );
  }
}

/// Section title, mirroring the tasks page's group headers.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Padding(
      padding:
          const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Text(label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: semantic.textTertiary,
          )),
    );
  }
}

/// One numbered plan step.
class _PlanStepRow extends StatelessWidget {
  const _PlanStepRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: semantic.floating,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text('$index',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: semantic.textSecondary,
                )),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(text,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.45,
                  color: semantic.textPrimary,
                )),
          ),
        ],
      ),
    );
  }
}

/// One tool-call entry of the action log.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final MissionAction action;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: semantic.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: semantic.border),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: semantic.floating,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text('${action.round}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: semantic.textSecondary,
                )),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.toolName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: semantic.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(
                  '${action.ok ? '成功' : '失败'} · ${action.durationMillis}ms',
                  style: TextStyle(
                      fontSize: 12, color: semantic.textTertiary),
                ),
              ],
            ),
          ),
          Icon(
            action.ok ? Icons.check_rounded : Icons.close_rounded,
            size: 16,
            color:
                action.ok ? semantic.success : semantic.danger,
          ),
        ],
      ),
    );
  }
}

/// One-line hint shown in place of an empty section list (matches the
/// tasks page's `_HintCard` pattern).
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
          style:
              TextStyle(fontSize: 12.5, color: semantic.textSecondary)),
    );
  }
}
