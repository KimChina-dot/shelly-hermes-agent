// The summarizer is injected under a public constructor name while the
// field stays private, matching the memory_extractor.dart convention.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'memory_store.dart' show MemoryFact, MemoryStore;

/// Memory tiers (PHASE 47, Letta-style): core facts always ride in the
/// system prompt, recall facts fill the auto-injection budget, and archival
/// facts are only surfaced on demand.
///
/// CONTRACT MIRROR: the canonical `MemoryTier` lives in memory_store.dart on
/// the tiered-memory branch. This file must compile unchanged both before
/// (this worktree's base) and after that branch lands, so the enum is
/// mirrored here and the memory_store import deliberately shows only
/// `MemoryFact`/`MemoryStore` — the canonical enum is never imported, so the
/// two declarations can never conflict. Tiers cross the fact/store boundary
/// as enum *names* (see [_tierOf] and [_WorkingFact.toJson]), which is
/// exactly how the tiered store serializes them, so behavior is identical
/// on both sides of the sibling merge.
enum MemoryTier {
  /// Stored for safekeeping; never auto-injected (retrieved on demand).
  archival,

  /// Default tier: auto-injected with the newest facts first.
  recall,

  /// Always auto-injected, exempt from age-based pruning.
  core,
}

/// Counts produced by one [MemoryConsolidator.consolidate] pass.
class ConsolidationReport {
  const ConsolidationReport({
    this.merged = 0,
    this.demoted = 0,
    this.evicted = 0,
    this.synthesized = 0,
  });

  /// Facts folded away by near-duplicate merging (group size minus one per
  /// merge group — including the group a synthesized fact replaces).
  final int merged;

  /// Recall facts demoted to archival because they aged out.
  final int demoted;

  /// Archival facts dropped because the tier exceeded its cap.
  final int evicted;

  /// New facts created by the summarizer to replace a merge group.
  final int synthesized;

  @override
  bool operator ==(Object other) =>
      other is ConsolidationReport &&
      other.merged == merged &&
      other.demoted == demoted &&
      other.evicted == evicted &&
      other.synthesized == synthesized;

  @override
  int get hashCode => Object.hash(merged, demoted, evicted, synthesized);

  @override
  String toString() =>
      'ConsolidationReport(merged: $merged, demoted: $demoted, '
      'evicted: $evicted, synthesized: $synthesized)';
}

/// Sleep-time memory consolidation (PHASE 47, Letta-style): one deterministic
/// maintenance pass that moves raw context into organized memory OFF the chat
/// loop — wiring (shell init / WorkManager wake / manual button) is the
/// controller's job.
///
/// The pass is best-effort on the summarizer and strict everywhere else:
/// a broken or empty summarizer reply keeps the plain merge result, and every
/// other step is pure bookkeeping. One pass performs, in order:
///
/// 1. **Near-duplicate merge** — facts whose token-Jaccard similarity is at
///    least [mergeThreshold] (0.6) and that share a tier are merged older
///    into newer: the survivor keeps the newest fact's id, createdAt and
///    sourceConversationId, and carries the SHORTER text of the group.
/// 2. **Synthesis (optional)** — when a summarizer is injected and a merge
///    group holds at least [minSynthesisGroupSize] facts, the summarizer is
///    asked for ONE synthesized text to replace the whole group; failures,
///    nulls and empty replies keep the merge result.
/// 3. **Aging** — recall facts older than [recallAgeDays] demote to archival.
///    Core facts are exempt (they never age), archival facts cannot age.
/// 4. **Archival cap** — when the archival tier holds more than
///    [archivalCap] facts, the oldest are evicted.
///
/// Persistence note: the store contract offers no fact-removal API (merging
/// and eviction are impossible through `addFacts`/`promote` alone), so the
/// pass persists its result by rewriting the full fact list under
/// [MemoryStore.storageKey] — the same key and JSON shape the store itself
/// uses. The rewrite is skipped entirely when nothing changed, and facts
/// added to the store while the pass was running (the summarizer may await a
/// slow model call) are re-read and appended so they are never clobbered.
class MemoryConsolidator {
  MemoryConsolidator({
    DateTime Function()? clock,
    Future<String?> Function(List<MemoryFact> group)? summarizer,
    this.recallAgeDays = 45,
    this.archivalCap = 300,
  })  : _clock = clock ?? DateTime.now,
        _summarizer = summarizer;

  /// Injectable clock, for deterministic aging in tests.
  final DateTime Function() _clock;

  /// Optional async summarizer; receives the raw facts of one merge group
  /// (at least [minSynthesisGroupSize]) and answers with a single
  /// synthesized fact text, or null/throws to keep the merge result.
  final Future<String?> Function(List<MemoryFact> group)? _summarizer;

  /// Recall facts older than this many days demote to archival.
  final int recallAgeDays;

  /// Maximum number of archival facts; the oldest overflow is evicted.
  final int archivalCap;

  /// Token-Jaccard similarity at which two same-tier facts count as
  /// near-duplicates and merge.
  static const double mergeThreshold = 0.6;

  /// Merge groups of at least this many facts are offered to the summarizer.
  static const int minSynthesisGroupSize = 3;

  /// Runs ONE consolidation pass over [store] and persists the result.
  /// Returns the counts; an empty (or untouched) store produces an all-zero
  /// report and no write.
  Future<ConsolidationReport> consolidate(MemoryStore store) async {
    final now = _clock();
    final facts = store.loadFacts();
    if (facts.isEmpty) return const ConsolidationReport();

    // Tier names persisted under the store's own key are the interop format
    // shared by both store generations; they let this pass recover each
    // fact's tier even on a store whose MemoryFact does not carry the field.
    final prefs = await SharedPreferences.getInstance();
    final storedTiers = _storedTierNames(prefs);

    final working = [
      for (final fact in facts)
        _WorkingFact(
          id: fact.id,
          text: fact.text,
          createdAt: fact.createdAt,
          sourceConversationId: fact.sourceConversationId,
          tier: _tierOf(fact, storedTiers),
          tokens: _tokens(fact.text),
        ),
    ];

    var merged = 0;
    var demoted = 0;
    var evicted = 0;
    var synthesized = 0;

    // 1 + 2) Near-duplicate merge and optional synthesis, per tier. Groups
    // are single-linkage over the threshold, discovered in store order
    // (oldest first) so the outcome is deterministic.
    final groups = _mergeGroups(working);
    final survivorAt = List<_WorkingFact?>.filled(working.length, null);
    for (final group in groups) {
      if (group.length == 1) {
        survivorAt[group.first] = working[group.first];
        continue;
      }
      // Survivor: the newest fact (latest createdAt, later store position
      // breaking ties); merged text: the shortest text (earlier store
      // position breaking ties).
      var survivorIndex = group.first;
      for (final index in group) {
        if (working[index].createdAt.isAfter(working[survivorIndex].createdAt)) {
          survivorIndex = index;
        }
      }
      var shortestIndex = group.first;
      for (final index in group) {
        if (working[index].text.length <
            working[shortestIndex].text.length) {
          shortestIndex = index;
        }
      }
      final survivor = working[survivorIndex];
      final mergedFact = _WorkingFact(
        id: survivor.id,
        text: working[shortestIndex].text,
        createdAt: survivor.createdAt,
        sourceConversationId: survivor.sourceConversationId,
        tier: survivor.tier,
        tokens: survivor.tokens,
      );
      if (_summarizer != null &&
          group.length >= minSynthesisGroupSize &&
          await _synthesize(group.map((i) => working[i].asFact()).toList(),
              mergedFact)) {
        synthesized += 1;
      }
      survivorAt[survivorIndex] = mergedFact;
      merged += group.length - 1;
    }

    // 3) Aging: recall facts past their age demote to archival; core and
    // archival facts are untouched.
    for (final fact in survivorAt) {
      if (fact != null &&
          fact.tier == MemoryTier.recall &&
          now.difference(fact.createdAt) > Duration(days: recallAgeDays)) {
        fact.tier = MemoryTier.archival;
        demoted += 1;
      }
    }

    // 4) Archival cap: the oldest archival facts are evicted first (index
    // breaks createdAt ties deterministically).
    final archival = [
      for (var i = 0; i < survivorAt.length; i++)
        if (survivorAt[i] != null && survivorAt[i]!.tier == MemoryTier.archival)
          i,
    ]..sort((a, b) {
        final byAge =
            survivorAt[a]!.createdAt.compareTo(survivorAt[b]!.createdAt);
        return byAge != 0 ? byAge : a.compareTo(b);
      });
    for (var i = 0; i < archival.length - archivalCap; i++) {
      survivorAt[archival[i]] = null;
      evicted += 1;
    }

    final result = [
      for (final fact in survivorAt) ?fact,
    ];
    if (merged == 0 && demoted == 0 && evicted == 0 && synthesized == 0) {
      return const ConsolidationReport();
    }

    // Concurrent-add safety: the summarizer may have awaited a slow model
    // call, and the chat loop may have learned facts in the meantime. Re-read
    // the store and append anything this pass had not seen at its start, so
    // the rewrite never clobbers concurrent learning — while merged-away and
    // evicted facts (ids known since the start) stay gone.
    final seenIds = {for (final fact in working) fact.id};
    result.addAll([
      for (final fact in store.loadFacts())
        if (!seenIds.contains(fact.id))
          _WorkingFact(
            id: fact.id,
            text: fact.text,
            createdAt: fact.createdAt,
            sourceConversationId: fact.sourceConversationId,
            tier: _tierOf(fact, storedTiers),
            tokens: _tokens(fact.text),
          ),
    ]);

    await prefs.setString(
      MemoryStore.storageKey,
      jsonEncode([for (final fact in result) fact.toJson()]),
    );
    return ConsolidationReport(
      merged: merged,
      demoted: demoted,
      evicted: evicted,
      synthesized: synthesized,
    );
  }

  /// Asks the summarizer to replace [group]'s merged result (carried in
  /// [into]) with one synthesized fact. Returns true on success; nulls,
  /// empty replies and thrown errors keep the merge result.
  Future<bool> _synthesize(List<MemoryFact> group, _WorkingFact into) async {
    try {
      final text = (await _summarizer!(group))?.trim();
      if (text == null || text.isEmpty) return false;
      into.text = text;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Groups indexes of same-tier near-duplicate facts (single-linkage over
  /// [mergeThreshold]); singleton groups are included so callers can treat
  /// the partition uniformly.
  List<List<int>> _mergeGroups(List<_WorkingFact> facts) {
    final groups = <_MergeGroup>[];
    for (var i = 0; i < facts.length; i++) {
      _MergeGroup? home;
      for (final group in groups) {
        if (group.tier != facts[i].tier) continue;
        for (final member in group.members) {
          if (_jaccard(facts[i].tokens, facts[member].tokens) >=
              mergeThreshold) {
            home = group;
            break;
          }
        }
        if (home != null) break;
      }
      if (home == null) {
        home = _MergeGroup(facts[i].tier);
        groups.add(home);
      }
      home.members.add(i);
    }
    return [for (final group in groups) group.members];
  }

  /// The fact's injection tier. Reads the tiered store's `tier` field when
  /// it exists and bridges it by enum name; on the pre-tier base the field
  /// is absent, so the tier name persisted in the store's own JSON (the
  /// interop format both generations share, e.g. written by an earlier
  /// consolidation pass) is used instead; with neither source available the
  /// fact is implicitly [MemoryTier.recall] — the documented default.
  static MemoryTier _tierOf(
    MemoryFact fact,
    Map<String, String> storedTiers,
  ) {
    final names = <String?>[null, null];
    try {
      final value = (fact as dynamic).tier;
      names[0] = value is Enum ? value.name : (value is String ? value : null);
    } on NoSuchMethodError {
      // Pre-tier MemoryFact: no tier field to read.
    }
    names[1] = storedTiers[fact.id];
    for (final name in names) {
      if (name == null) continue;
      for (final tier in MemoryTier.values) {
        if (tier.name == name) return tier;
      }
    }
    return MemoryTier.recall;
  }

  /// Tier names per fact id from the store's persisted JSON; tolerated to be
  /// absent, malformed or stale (a malformed payload simply yields no tiers).
  static Map<String, String> _storedTierNames(SharedPreferences prefs) {
    final raw = prefs.getString(MemoryStore.storageKey);
    if (raw == null) return const {};
    try {
      final entries = jsonDecode(raw);
      if (entries is! List) return const {};
      final tiers = <String, String>{};
      for (final entry in entries) {
        if (entry is Map<String, dynamic> &&
            entry['id'] is String &&
            entry['tier'] is String) {
          tiers[entry['id'] as String] = entry['tier'] as String;
        }
      }
      return tiers;
    } on FormatException {
      return const {};
    }
  }

  /// Similarity of two texts as token sets: ASCII word runs stay whole, and
  /// every non-ASCII (CJK) character counts as its own token, which keeps
  /// the Jaccard meaningful for the app's Chinese facts.
  static Set<String> _tokens(String text) => {
        for (final match
            in RegExp(r'[a-z0-9_]+|[^ -~]', caseSensitive: false)
                .allMatches(text.toLowerCase()))
          match.group(0)!,
      };

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var shared = 0;
    for (final token in a) {
      if (b.contains(token)) shared += 1;
    }
    return shared / (a.length + b.length - shared);
  }
}

/// One fact under consolidation: the store's record fields plus the tier
/// view and the pre-tokenized text. Fields are mutable because merging and
/// demotion rewrite them in place before persistence.
class _WorkingFact {
  _WorkingFact({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.sourceConversationId,
    required this.tier,
    required this.tokens,
  });

  final String id;
  final DateTime createdAt;
  final String? sourceConversationId;
  String text;
  MemoryTier tier;
  final Set<String> tokens;

  /// The plain store fact this record was built from (or would serialize
  /// to) — handed to the summarizer.
  MemoryFact asFact() => MemoryFact(
        id: id,
        text: text,
        createdAt: createdAt,
        sourceConversationId: sourceConversationId,
      );

  /// Store-format JSON: identical shape to `MemoryFact.toJson`, plus the
  /// tier name. The tiered store decodes the tier; the pre-tier base simply
  /// ignores the extra key, so entries written here are forward-compatible.
  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'sourceConversationId': ?sourceConversationId,
        'tier': tier.name,
      };
}

/// Accumulates the member indexes of one same-tier merge group.
class _MergeGroup {
  _MergeGroup(this.tier);

  final MemoryTier tier;
  final List<int> members = [];
}
