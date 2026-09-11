// V3.1 搬迁锚点(PHASE 19 冻结,V3 计划 P14):move → lib/application/hermes_provider.dart。
// 账本快照编排归 application 层(与 mission_coordinator 同层);自身对
// chat_session/settings_store 的 import 改 '../state/...' 前缀。
// 命令与风险见 docs/audit/V31_MIGRATION_CHECKLIST.md M3;facade export 行是唯一 features 改写点。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hermes/forgetting.dart';
import '../core/hermes/knowledge.dart';
import '../core/hermes/knowledge_store.dart';
import '../core/hermes/memory_settings.dart';
import '../core/tools/workspace.dart';
import '../core/hermes/reflection.dart';
import 'chat_session.dart';
import 'settings_store.dart';

/// Everything the memory page needs to explain Hermes' current state:
/// the ledger entries, each entry's vitality, the token budget usage and
/// the user-tuned memory settings.
class HermesLedgerSnapshot {
  const HermesLedgerSnapshot({
    required this.entries,
    required this.vitality,
    required this.totalTokens,
    required this.settings,
  });

  final List<KnowledgeEntry> entries;

  /// Per-entry vitality under the configured forgetting policy.
  final Map<String, KnowledgeVitality> vitality;

  /// Estimated recall cost of the whole ledger (the forgetting budget).
  final int totalTokens;

  final MemorySettings settings;

  int countOf(KnowledgeVitality value) =>
      vitality.values.where((v) => v == value).length;

  KnowledgeVitality vitalityOf(KnowledgeEntry entry) =>
      vitality[entry.id] ?? KnowledgeVitality.active;
}

/// Runs reflection (forced) and a forgetting pass against the live ledger;
/// returns what got merged and what got dropped so the page can show a
/// report instead of silently mutating memory. Takes plain dependencies so
/// both Ref and WidgetRef callers can drive it.
Future<UpkeepReport> runUpkeepWith({
  required Workspace workspace,
  required String project,
  required MemorySettings settings,
}) async {
  final store = HermesKnowledgeStore(workspace: workspace, project: project);
  final policy = ForgettingPolicy(
    maxLedgerTokens: settings.maxLedgerTokens,
    activeDays: settings.activeDays,
    coolingDays: settings.coolingDays,
    frequencyFloor: settings.frequencyFloor,
  );

  final reflection = await const Reflector().reflect(store, force: true) ??
      const ReflectionReport(
          entriesBefore: 0, entriesAfter: 0, generalizedGroups: 0, absorbedIds: []);
  final forgetting = await store.applyForgetting(policy: policy);
  return UpkeepReport(
    mergedEntries: reflection.generalizedGroups,
    absorbedEntries: reflection.absorbedIds.length,
    droppedEntries: forgetting.droppedIds.length,
    remainingEntries: forgetting.kept.length,
    droppedReasons: forgetting.droppedReasons,
  );
}

/// Outcome of a manual 立即整理 run, for the memory page report card.
class UpkeepReport {
  const UpkeepReport({
    required this.mergedEntries,
    required this.absorbedEntries,
    required this.droppedEntries,
    required this.remainingEntries,
    required this.droppedReasons,
  });

  final int mergedEntries;
  final int absorbedEntries;
  final int droppedEntries;
  final int remainingEntries;
  final Map<String, String> droppedReasons;
}

/// Loads the live Hermes ledger from the active workspace so the memory
/// page can explain what the agent remembers and why.
final hermesLedgerProvider =
    FutureProvider.autoDispose<HermesLedgerSnapshot>((ref) async {
  final workspace = ref.watch(workspaceProvider);
  final manager = ref.watch(workspaceManagerProvider);
  final project = await manager.detectProject();
  final store = HermesKnowledgeStore(workspace: workspace, project: project.name);
  final settings =
      ref.watch(settingsStoreProvider).asData?.value.loadMemorySettings() ??
          const MemorySettings();
  final entries = await store.loadAll();
  final policy = ForgettingPolicy(
    maxLedgerTokens: settings.maxLedgerTokens,
    activeDays: settings.activeDays,
    coolingDays: settings.coolingDays,
    frequencyFloor: settings.frequencyFloor,
  );
  final now = DateTime.now();
  return HermesLedgerSnapshot(
    entries: entries,
    vitality: {
      for (final entry in entries) entry.id: policy.vitalityOf(entry, now),
    },
    totalTokens:
        entries.fold<int>(0, (sum, entry) => sum + estimateTokens(entry.content)),
    settings: settings,
  );
});
