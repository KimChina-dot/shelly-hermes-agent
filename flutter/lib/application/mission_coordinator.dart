import 'dart:async';

import '../../core/events/agent_events.dart';
import '../../core/events/event_bus.dart';
import '../../domain/agent/mission.dart';
import '../../domain/agent/mission_store.dart';

/// One recorded tool call: an entry of the coordinator-local action log.
///
/// The v3 [AgentMission] model has no actions list, so tool-call records
/// are kept in memory only ([MissionCoordinator.recentActions]) and are
/// not persisted — a documented PHASE 2 choice.
class MissionAction {
  const MissionAction({
    required this.missionId,
    required this.toolName,
    required this.ok,
    required this.durationMillis,
    required this.round,
  });

  /// Mission handle the action belongs to (as passed by the caller).
  final String missionId;

  /// Tool name, as reported by the engine's [ToolFinished]-style event.
  final String toolName;

  /// Whether the tool call succeeded.
  final bool ok;

  /// Wall-clock duration of the tool call.
  final int durationMillis;

  /// Model round the tool call belonged to.
  final int round;
}

/// Bridges the chat task lifecycle onto the v3 Mission domain (PHASE 2 of
/// docs/audit/V3_MIGRATION_PLAN.md): Mission = chat task, Step = model
/// round, Action = tool call.
///
/// Every method is best-effort and fully guarded: bookkeeping failures are
/// swallowed so the chat can never break. Store writes are fire-and-forget;
/// the only sequencing guarantee is that events and terminal transitions
/// are chained after the mission's creation future, so a fast-failing task
/// still lands a legal `executing → completed | failed` edge and no event
/// ever precedes [MissionCreated].
///
/// Identity note: [MissionStore.createMission] mints its own id
/// asynchronously, while the chat needs a stable token back synchronously.
/// [startForConversation] therefore returns a coordinator-issued *handle*
/// that callers pass back into [recordRound] / [recordToolCall] /
/// [complete]; the handle→store-id mapping is internal, and every
/// [MissionEvent] published on the bus carries the real store mission id.
/// [complete] additionally accepts a raw store id; unknown ids are simply
/// swallowed.
///
/// Round coverage: [StepStarted] carries each model round (published from
/// [recordRound]); [recordToolCall] deliberately publishes nothing extra —
/// the [MissionEvent] family has no tool-call event and steps already mark
/// the rounds.
class MissionCoordinator {
  MissionCoordinator({required this.store, required this.bus});

  /// Sentinel [startForConversation] returns when mission bookkeeping could
  /// not even be started; callers skip all further bookkeeping for the task.
  static const String noMission = '';

  /// Cap of the coordinator-local action ring (oldest dropped first).
  static const int maxLocalActions = 100;

  final MissionStore store;
  final AgentEventBus bus;

  /// Mission handle → creation chain resolving to the store-side mission
  /// id (null when creation or the planning→executing move failed). Entries
  /// are kept for the coordinator's lifetime — the map is tiny (one entry
  /// per chat task) and keeping it lets late rounds still resolve.
  final Map<String, Future<String?>> _resolves = {};

  /// Coordinator-local action log (newest last). Not persisted — the v3
  /// mission model carries no actions list (see [MissionAction]).
  final List<MissionAction> recentActions = [];

  int _nextHandle = 0;

  /// Creates a mission for one chat task ([MissionStatus.executing], title
  /// = first 30 characters of [userText]) and publishes [MissionCreated]
  /// once the store reflects it. Returns the mission handle, or
  /// [noMission] on an immediate failure; later store failures simply drop
  /// this mission's bookkeeping (all methods become no-ops for the handle).
  String startForConversation(String conversationId, String userText) {
    try {
      final now = DateTime.now();
      final handle =
          'mission-bridge-${_nextHandle++}-${now.millisecondsSinceEpoch}';
      final title = _titleFrom(userText);
      final goalId = conversationId.isEmpty ? 'goal-adhoc' : conversationId;
      _resolves[handle] = () async {
        try {
          final mission = await store.createMission(
            goalId: goalId,
            title: title,
            at: now,
          );
          // planning → executing before MissionCreated: listeners can rely
          // on the store already showing an executing mission.
          await store.changeStatus(mission.id, MissionStatus.executing,
              at: now);
          bus.publish(MissionCreated(
            missionId: mission.id,
            title: title,
            at: now,
          ));
          return mission.id;
        } catch (_) {
          return null; // best-effort: drop this mission's bookkeeping.
        }
      }();
      return handle;
    } catch (_) {
      return noMission;
    }
  }

  /// Publishes [StepStarted] for one model round.
  ///
  /// [taskId] is the chat task id the round belongs to (empty when
  /// unknown). Rounds for a mission still being created are chained after
  /// the creation future, so they never precede [MissionCreated]. Unknown
  /// ids are dropped silently — a round only makes sense for a mission this
  /// coordinator started or already resolved ([complete] keeps the
  /// direct-store-id fallback; this method does not).
  void recordRound(
    String missionId, {
    required int round,
    String taskId = '',
  }) {
    if (missionId.isEmpty) return;
    final tracked = _resolves[missionId];
    if (tracked == null) return;
    unawaited(() async {
      try {
        final storeId = await tracked;
        if (storeId == null || storeId.isEmpty) return;
        bus.publish(StepStarted(
          missionId: storeId,
          taskId: taskId,
          stepIndex: round,
          at: DateTime.now(),
        ));
      } catch (_) {
        // Bookkeeping must never break the chat.
      }
    }());
  }

  /// Records one tool call in the coordinator-local action log.
  ///
  /// Publishes nothing extra: [StepStarted] (per [recordRound]) already
  /// covers round boundaries and the [MissionEvent] family has no
  /// tool-call event. The v3 [AgentMission] has no actions field, so this
  /// is an in-memory ring ([recentActions]) rather than a store write.
  void recordToolCall(
    String missionId, {
    required String toolName,
    required bool ok,
    required int durationMillis,
    required int round,
  }) {
    if (missionId.isEmpty) return;
    try {
      recentActions.add(MissionAction(
        missionId: missionId,
        toolName: toolName,
        ok: ok,
        durationMillis: durationMillis,
        round: round,
      ));
      if (recentActions.length > maxLocalActions) {
        recentActions.removeRange(0, recentActions.length - maxLocalActions);
      }
    } catch (_) {
      // Bookkeeping must never break the chat.
    }
  }

  /// Moves the mission to [MissionStatus.completed] — or
  /// [MissionStatus.failed] when [error] is non-null — and publishes
  /// [MissionCompleted] / [MissionFailed] accordingly.
  ///
  /// Waits for the mission's creation chain first, so a task that fails
  /// before the store record exists still lands a legal transition.
  void complete(String missionId, {String? error}) {
    if (missionId == noMission) return;
    final tracked = _resolves[missionId];
    unawaited(() async {
      try {
        final storeId = tracked == null ? missionId : await tracked;
        if (storeId == null || storeId.isEmpty) return;
        final now = DateTime.now();
        if (error == null) {
          await store.changeStatus(storeId, MissionStatus.completed, at: now);
          bus.publish(MissionCompleted(missionId: storeId, at: now));
        } else {
          await store.changeStatus(storeId, MissionStatus.failed, at: now);
          bus.publish(MissionFailed(
            missionId: storeId,
            error: error,
            at: now,
          ));
        }
      } catch (_) {
        // Bookkeeping must never break the chat (unknown mission, illegal
        // double transition, broken prefs — all swallowed).
      }
    }());
  }

  /// Mission title: first 30 characters of the user text, whitespace
  /// flattened (mirrors the conversation-title heuristic in chat_session).
  static String _titleFrom(String userText) {
    final flat = userText.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 30 ? flat : flat.substring(0, 30);
  }
}
