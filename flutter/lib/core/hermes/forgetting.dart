import 'knowledge.dart';

/// Vitality of a ledger entry, driven by frequency and recency of recall.
enum KnowledgeVitality { active, cooling, expired }

/// Forgetting knobs (PHASE 10). Budget targets ≈2000 tokens for the whole
/// ledger so recall stays cheap and context-safe.
class ForgettingPolicy {
  const ForgettingPolicy({
    this.activeDays = 7,
    this.coolingDays = 30,
    this.frequencyFloor = 3,
    this.maxLedgerTokens = 2000,
  });

  /// Entries recalled within this window are active.
  final int activeDays;

  /// Entries last recalled within this window are cooling; older ones are
  /// expired (unless [frequencyFloor] protects them).
  final int coolingDays;

  /// Frequently-triggered knowledge never expires on age alone.
  final int frequencyFloor;

  final int maxLedgerTokens;

  KnowledgeVitality vitalityOf(KnowledgeEntry entry, DateTime now) {
    final age = now.difference(entry.lastTriggeredAt);
    if (entry.frequency >= frequencyFloor) {
      return age.inDays > coolingDays * 4
          ? KnowledgeVitality.expired
          : KnowledgeVitality.active;
    }
    if (age.inDays <= activeDays) return KnowledgeVitality.active;
    if (age.inDays <= coolingDays) return KnowledgeVitality.cooling;
    return KnowledgeVitality.expired;
  }
}

class ForgettingReport {
  const ForgettingReport({
    required this.kept,
    required this.droppedIds,
    required this.droppedReasons,
  });

  final List<KnowledgeEntry> kept;
  final List<String> droppedIds;
  final Map<String, String> droppedReasons;

  bool get isEmpty => droppedIds.isEmpty;
}

/// Drops expired entries, then keeps the hottest entries (most recent
/// trigger, then highest frequency) until the ledger fits the token
/// budget. Deterministic; the kept list is returned in creation order.
ForgettingReport forget(
  List<KnowledgeEntry> entries, {
  ForgettingPolicy policy = const ForgettingPolicy(),
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final dropped = <String>[];
  final reasons = <String, String>{};

  final survivors = <KnowledgeEntry>[];
  for (final entry in entries) {
    if (policy.vitalityOf(entry, clock) == KnowledgeVitality.expired) {
      dropped.add(entry.id);
      reasons[entry.id] = 'expired';
    } else {
      survivors.add(entry);
    }
  }

  final hot = survivors.toList()
    ..sort((a, b) {
      final byTrigger = b.lastTriggeredAt.millisecondsSinceEpoch
          .compareTo(a.lastTriggeredAt.millisecondsSinceEpoch);
      if (byTrigger != 0) return byTrigger;
      final byFreq = b.frequency.compareTo(a.frequency);
      if (byFreq != 0) return byFreq;
      return a.id.compareTo(b.id);
    });

  final kept = <KnowledgeEntry>[];
  var budget = 0;
  for (final entry in hot) {
    final cost = estimateTokens(entry.content);
    if (kept.isNotEmpty && budget + cost > policy.maxLedgerTokens) {
      dropped.add(entry.id);
      reasons[entry.id] = 'over_token_budget';
      continue;
    }
    kept.add(entry);
    budget += cost;
  }
  kept.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return ForgettingReport(
    kept: kept,
    droppedIds: dropped,
    droppedReasons: reasons,
  );
}
