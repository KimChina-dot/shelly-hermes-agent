import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hermes/forgetting.dart';
import '../core/hermes/knowledge.dart';
import '../core/hermes/knowledge_store.dart';
import 'chat_session.dart';

/// Everything the memory page needs to explain Hermes' current state:
/// the ledger entries, each entry's vitality, and the token budget usage.
class HermesLedgerSnapshot {
  const HermesLedgerSnapshot({
    required this.entries,
    required this.vitality,
    required this.totalTokens,
  });

  final List<KnowledgeEntry> entries;

  /// Per-entry vitality under the default forgetting policy.
  final Map<String, KnowledgeVitality> vitality;

  /// Estimated recall cost of the whole ledger (the forgetting budget).
  final int totalTokens;

  int countOf(KnowledgeVitality value) =>
      vitality.values.where((v) => v == value).length;

  KnowledgeVitality vitalityOf(KnowledgeEntry entry) =>
      vitality[entry.id] ?? KnowledgeVitality.active;
}

/// Loads the live Hermes ledger from the active workspace so the memory
/// page can explain what the agent remembers and why.
final hermesLedgerProvider =
    FutureProvider.autoDispose<HermesLedgerSnapshot>((ref) async {
  final workspace = ref.watch(workspaceProvider);
  final manager = ref.watch(workspaceManagerProvider);
  final project = await manager.detectProject();
  final store = HermesKnowledgeStore(workspace: workspace, project: project.name);
  final entries = await store.loadAll();
  final policy = const ForgettingPolicy();
  final now = DateTime.now();
  return HermesLedgerSnapshot(
    entries: entries,
    vitality: {
      for (final entry in entries) entry.id: policy.vitalityOf(entry, now),
    },
    totalTokens:
        entries.fold<int>(0, (sum, entry) => sum + estimateTokens(entry.content)),
  );
});
