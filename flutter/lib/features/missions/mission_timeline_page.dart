import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/mission_coordinator.dart';
import '../../shelly_facade.dart';
import '../../design/components/empty_state.dart';
import '../../design/components/motion.dart';
import '../../design/tokens.dart';
import '../../domain/agent/mission.dart';
import 'mission_detail_page.dart';

/// Semantic tone a [MissionStatus] renders in; the concrete color resolves
/// against the per-brightness palette in [_toneColor].
enum MissionTone { brand, success, warning, danger, neutral }

/// Read-only presentation mapping for one [MissionStatus]: user-visible
/// label, icon and semantic tone. Kept as a pure record so tests (and the
/// detail page) share the exact same visuals as the list.
class MissionStatusVisual {
  const MissionStatusVisual(this.label, this.icon, this.tone);

  final String label;
  final IconData icon;
  final MissionTone tone;
}

/// Status visuals for every [MissionStatus] (used by both the list cards
/// and the detail page, so the two can never drift apart).
const Map<MissionStatus, MissionStatusVisual> missionStatusVisuals = {
  MissionStatus.planning:
      MissionStatusVisual('规划中', Icons.edit_note_outlined, MissionTone.neutral),
  MissionStatus.executing:
      MissionStatusVisual('执行中', Icons.play_arrow_rounded, MissionTone.brand),
  MissionStatus.waitingApproval: MissionStatusVisual(
      '待审批', Icons.hourglass_top_rounded, MissionTone.warning),
  MissionStatus.completed: MissionStatusVisual(
      '已完成', Icons.check_circle_outline_rounded, MissionTone.success),
  MissionStatus.failed:
      MissionStatusVisual('已失败', Icons.error_outline_rounded, MissionTone.danger),
  MissionStatus.cancelled:
      MissionStatusVisual('已取消', Icons.cancel_outlined, MissionTone.neutral),
};

/// Resolve a tone into a concrete color against the active palette.
Color missionToneColor(MissionTone tone, AppSemanticColors semantic) {
  switch (tone) {
    case MissionTone.brand:
      return AppColors.brandBlue;
    case MissionTone.success:
      return semantic.success;
    case MissionTone.warning:
      return semantic.warning;
    case MissionTone.danger:
      return semantic.danger;
    case MissionTone.neutral:
      return semantic.textSecondary;
  }
}

/// Steps recorded for [mission], derived from public read surfaces only:
/// the persisted plan length, raised to the number of distinct round
/// indexes the mission event bus has seen for this mission (chat missions
/// carry no persisted plan — their rounds live on the in-process bus).
int missionStepCount(AgentMission mission, List<MissionEvent> events) {
  final rounds = <int>{};
  for (final event in events) {
    if (event is StepStarted && event.missionId == mission.id) {
      rounds.add(event.stepIndex);
    }
  }
  return mission.plan.length > rounds.length
      ? mission.plan.length
      : rounds.length;
}

/// Chronological (oldest first) actions logged for [missionId].
///
/// Note the PHASE 2 id caveat: chat-created missions record actions under
/// the coordinator-issued handle, so those rows surface in the detail view
/// only when ids line up; entries recorded with the store id (as
/// [MissionCoordinator.complete] also accepts) always match.
List<MissionAction> missionActionsFor(
  String missionId,
  List<MissionAction> actions,
) =>
    [for (final action in actions) if (action.missionId == missionId) action];

/// Fixed `yyyy-MM-dd HH:mm` stamp — deterministic, clock-free, test-safe.
String formatMissionTime(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// Mission timeline (PHASE 13, v3 read-side): every mission the store
/// holds, newest first, with status, step count and the latest logged
/// action per card. Read-only — the page never writes to the store, the
/// coordinator or the bus; it only re-reads when a mission event lands
/// (the bus subscription in [initState] bumps the revision).
class MissionTimelinePage extends ConsumerStatefulWidget {
  const MissionTimelinePage({super.key});

  @override
  ConsumerState<MissionTimelinePage> createState() =>
      _MissionTimelinePageState();
}

class _MissionTimelinePageState extends ConsumerState<MissionTimelinePage> {
  StreamSubscription<MissionEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(missionBusProvider)
        .subscribe()
        .listen((_) => _refresh());
  }

  /// Re-runs build (which re-reads the store, coordinator and bus) so the
  /// list tracks chat activity live while mounted.
  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final storeAsync = ref.watch(missionStoreProvider);
    final coordinator = ref.watch(missionCoordinatorProvider).value;
    final bus = ref.watch(missionBusProvider);
    final missions =
        storeAsync.value?.listMissions() ?? const <AgentMission>[];

    final Widget body;
    if (storeAsync.isLoading) {
      // Brief first resolve; never an animated placeholder (motion
      // discipline + test pumpAndSettle safety inside the IndexedStack).
      body = const SizedBox.shrink();
    } else if (storeAsync.value == null) {
      body = EmptyState(
        icon: Icons.timeline_outlined,
        title: '使命记录不可用',
        body: '当前环境无法读取本地存储,使命时间线暂时不可用。',
      );
    } else if (missions.isEmpty) {
      body = EmptyState(
        icon: Icons.timeline_outlined,
        title: '暂无使命',
        body: '在对话页发起请求后,每个任务会作为一个使命记录在这里,'
            '可以随时回顾执行状态、步骤与动作日志。',
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: missions.length,
        itemBuilder: (context, index) {
          final mission = missions[index];
          final actions = missionActionsFor(
            mission.id,
            coordinator?.recentActions ?? const <MissionAction>[],
          );
          return StaggerIn(
            index: index,
            child: _MissionCard(
              mission: mission,
              steps: missionStepCount(mission, bus.replayBuffer),
              latestAction: actions.isEmpty ? null : actions.last,
              onOpen: () => _openDetail(mission, bus),
            ),
          );
        },
      );
    }

    return Scaffold(
      backgroundColor: semantic.background,
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: Text('使命',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: semantic.textPrimary)),
      ),
      body: body,
    );
  }

  /// Pushes the read-only detail view with a snapshot of everything the
  /// public surfaces currently report for [mission].
  void _openDetail(AgentMission mission, AgentEventBus bus) {
    final coordinator = ref.read(missionCoordinatorProvider).value;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MissionDetailPage(
          mission: mission,
          events: bus.replayBuffer,
          actions: missionActionsFor(
            mission.id,
            coordinator?.recentActions ?? const <MissionAction>[],
          ),
        ),
      ),
    );
  }
}

/// One mission row: title, status pill, step/task/time meta and the most
/// recent logged action. Tapping opens the detail view — the only
/// interaction this read-only surface offers.
class _MissionCard extends StatelessWidget {
  const _MissionCard({
    required this.mission,
    required this.steps,
    required this.latestAction,
    required this.onOpen,
  });

  final AgentMission mission;
  final int steps;
  final MissionAction? latestAction;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final visual = missionStatusVisuals[mission.status]!;
    final color = missionToneColor(visual.tone, semantic);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: semantic.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: semantic.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        mission.title.isEmpty ? '(未命名使命)' : mission.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: semantic.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _StatusPill(visual: visual, color: color, id: mission.id),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '$steps 步 · ${mission.taskIds.length} 个任务 · '
                  '${formatMissionTime(mission.createdAt)}',
                  style: TextStyle(
                      fontSize: 12.5, color: semantic.textSecondary),
                ),
                const SizedBox(height: 6),
                if (latestAction != null)
                  Row(
                    children: [
                      Icon(
                        latestAction!.ok
                            ? Icons.check_rounded
                            : Icons.close_rounded,
                        size: 14,
                        color: latestAction!.ok
                            ? semantic.success
                            : semantic.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '最近动作 ${latestAction!.toolName} · '
                          '${latestAction!.durationMillis}ms',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: semantic.textTertiary),
                        ),
                      ),
                    ],
                  )
                else
                  Text('暂无动作记录',
                      style: TextStyle(
                          fontSize: 12, color: semantic.textTertiary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact status pill: tinted background at 12% plus icon and label in
/// the tone color. Keyed by mission id so tests can pin one mission's
/// visual without depending on list order.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.visual,
    required this.color,
    required this.id,
  });

  final MissionStatusVisual visual;
  final Color color;
  final String id;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('mission-status-$id'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(visual.icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            visual.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
