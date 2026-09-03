import 'knowledge.dart';
import 'knowledge_store.dart';

/// Reflection (V2.0 PHASE 09): when the ledger outgrows its caps
/// (> [maxEntries] entries or > [maxBytes] bytes of content), collapse it
/// — exact duplicates merge, near-duplicates in the same category fold
/// into one generalized entry sourced from the longest original. Pure
/// text heuristics; no model call, deterministic output.
class Reflector {
  const Reflector({
    this.maxEntries = 30,
    this.maxBytes = 4 * 1024,
    this.mergeThreshold = 0.7,
  });

  final int maxEntries;
  final int maxBytes;

  /// Jaccard similarity above which two same-category entries merge.
  final double mergeThreshold;

  bool shouldReflect(int entryCount, int contentBytes) =>
      entryCount > maxEntries || contentBytes > maxBytes;

  Future<ReflectionReport?> reflect(
    HermesKnowledgeStore store, {
    bool force = false,
  }) async {
    final entries = await store.loadAll();
    final bytes = entries.fold<int>(0, (sum, e) => sum + e.content.length);
    if (!force && !shouldReflect(entries.length, bytes)) return null;

    final merged = <KnowledgeEntry>[];
    final absorbed = <String>[];
    var generalized = 0;

    // Phase 1: exact duplicates (normalized equality).
    final byNormalized = <String, KnowledgeEntry>{};
    for (final entry in entries) {
      final key = normalizeForDedupe(entry.content);
      final existing = byNormalized[key];
      if (existing == null) {
        byNormalized[key] = entry;
        continue;
      }
      absorbed.add(entry.id);
      byNormalized[key] = _dominant(existing, entry);
    }
    var pool = byNormalized.values.toList();

    // Phase 2: near-duplicate folding within a category.
    final used = <String>{};
    for (var i = 0; i < pool.length; i++) {
      final a = pool[i];
      if (used.contains(a.id)) continue;
      final group = <KnowledgeEntry>[a];
      for (var j = i + 1; j < pool.length; j++) {
        final b = pool[j];
        if (used.contains(b.id) || b.category != a.category) continue;
        if (_jaccard(tokenize(a.content), tokenize(b.content)) >=
            mergeThreshold) {
          group.add(b);
          used.add(b.id);
        }
      }
      if (group.length == 1) {
        merged.add(a);
        continue;
      }
      used.add(a.id);
      generalized += 1;
      final longest = group.reduce((x, y) =>
          x.content.length >= y.content.length ? x : y);
      merged.add(KnowledgeEntry(
        id: longest.id,
        content: longest.content,
        category: longest.category,
        createdAt: group
            .map((e) => e.createdAt)
            .reduce((x, y) => x.isBefore(y) ? x : y),
        lastTriggeredAt: group
            .map((e) => e.lastTriggeredAt)
            .reduce((x, y) => x.isAfter(y) ? x : y),
        frequency: group.fold(0, (sum, e) => sum + e.frequency),
        source: 'reflection',
        project: longest.project,
      ));
      absorbed.addAll(group.map((e) => e.id).where((id) => id != longest.id));
    }

    await store.saveAll(merged);
    return ReflectionReport(
      entriesBefore: entries.length,
      entriesAfter: merged.length,
      generalizedGroups: generalized,
      absorbedIds: absorbed,
    );
  }

  KnowledgeEntry _dominant(KnowledgeEntry a, KnowledgeEntry b) =>
      a.content.length >= b.content.length
          ? a.copyWith(
              frequency: a.frequency + b.frequency,
              lastTriggeredAt: a.lastTriggeredAt.isAfter(b.lastTriggeredAt)
                  ? a.lastTriggeredAt
                  : b.lastTriggeredAt,
            )
          : b.copyWith(
              frequency: a.frequency + b.frequency,
              lastTriggeredAt: a.lastTriggeredAt.isAfter(b.lastTriggeredAt)
                  ? a.lastTriggeredAt
                  : b.lastTriggeredAt,
            );

  double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    return intersection / union;
  }
}

class ReflectionReport {
  const ReflectionReport({
    required this.entriesBefore,
    required this.entriesAfter,
    required this.generalizedGroups,
    required this.absorbedIds,
  });

  final int entriesBefore;
  final int entriesAfter;
  final int generalizedGroups;
  final List<String> absorbedIds;
}
