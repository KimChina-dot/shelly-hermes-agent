import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Letta-style memory tiers (PHASE 47): core facts always ride in the
/// system prompt, recall facts fill the auto-injection budget, and archival
/// facts are only surfaced through the search_memory tool.
enum MemoryTier {
  /// Stored for safekeeping; never auto-injected (retrieved on demand).
  archival,

  /// Default tier: auto-injected with the newest facts first, up to the
  /// prompt cap.
  recall,

  /// Always auto-injected, exempt from age-based pruning.
  core,
}

/// One durable fact the assistant learned about the user (PHASE 41): a
/// short preference or stable piece of personal context, captured from a
/// finished conversation round.
class MemoryFact {
  const MemoryFact({
    required this.id,
    required this.text,
    required this.createdAt,
    this.sourceConversationId,
    this.tier = MemoryTier.recall,
  });

  final String id;
  final String text;
  final DateTime createdAt;

  /// Conversation the fact was extracted from; informational only.
  final String? sourceConversationId;

  /// Injection tier (PHASE 47); defaults to [MemoryTier.recall] so records
  /// persisted before tiers existed load unchanged.
  final MemoryTier tier;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        if (sourceConversationId != null)
          'sourceConversationId': sourceConversationId,
        'tier': tier.name,
      };

  static MemoryFact fromJson(Map<String, dynamic> json) => MemoryFact(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        createdAt: json['createdAt'] is String
            ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        sourceConversationId: json['sourceConversationId'] as String?,
        tier: _tierFromName(json['tier']),
      );

  /// Lenient tier decode: unknown or missing names fall back to
  /// [MemoryTier.recall], matching pre-tier records.
  static MemoryTier _tierFromName(Object? value) {
    if (value is String) {
      for (final tier in MemoryTier.values) {
        if (tier.name == value) return tier;
      }
    }
    return MemoryTier.recall;
  }

  @override
  bool operator ==(Object other) =>
      other is MemoryFact &&
      other.id == id &&
      other.text == text &&
      other.createdAt == createdAt &&
      other.sourceConversationId == sourceConversationId &&
      other.tier == tier;

  @override
  int get hashCode => Object.hash(id, text, createdAt, sourceConversationId, tier);
}

/// Persistent automatic long-term memory (PHASE 41). Facts live in a single
/// JSON list under SharedPreferences (works on Android and the web dev
/// harness) and are matched case-insensitively on whitespace-normalized
/// text so a re-learned fact never duplicates. The list is capped and the
/// newest facts win.
class MemoryStore {
  MemoryStore(this._prefs);

  final SharedPreferences _prefs;

  static const storageKey = 'shelly.memory.facts';

  /// Hard cap on stored facts; the newest ones win.
  static const int maxFacts = 200;

  /// Process-wide id counter so facts created in the same millisecond stay
  /// unique (same trick as the chat transcript entry ids).
  static int _nextId = 0;

  /// All stored facts, oldest first.
  List<MemoryFact> loadFacts() {
    final raw = _prefs.getString(storageKey);
    if (raw == null) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry is Map<String, dynamic>) MemoryFact.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Appends the given texts as new facts, skipping anything that already
  /// exists (in the store or within [texts] itself, compared on normalized
  /// text) and persisting. Returns the facts that were actually added.
  ///
  /// An explicit [at] is for tests; production stamps the current time.
  Future<List<MemoryFact>> addFacts(
    List<String> texts, {
    String? sourceConversationId,
    DateTime? at,
  }) async {
    final existing = {
      for (final fact in loadFacts()) normalize(fact.text),
    };
    final reference = DateTime.now();
    final added = <MemoryFact>[];
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      final key = normalize(trimmed);
      if (existing.contains(key)) continue;
      existing.add(key);
      added.add(MemoryFact(
        id: 'm-${_nextId++}-${reference.millisecondsSinceEpoch}',
        text: trimmed,
        createdAt: at ?? reference,
        sourceConversationId: sourceConversationId,
      ));
    }
    if (added.isEmpty) return added;
    await _save([...loadFacts(), ...added]);
    return added;
  }

  /// Re-tiers the fact with [id] to [tier] (PHASE 47) and persists. Moves
  /// in either direction are allowed (promote to core or demote to
  /// archival). Returns the updated fact, or null when no fact with that
  /// id exists.
  Future<MemoryFact?> promote(String id, MemoryTier tier) async {
    final facts = loadFacts();
    final index = facts.indexWhere((fact) => fact.id == id);
    if (index < 0) return null;
    final current = facts[index];
    final updated = MemoryFact(
      id: current.id,
      text: current.text,
      createdAt: current.createdAt,
      sourceConversationId: current.sourceConversationId,
      tier: tier,
    );
    final next = [...facts]..[index] = updated;
    await _save(next);
    return updated;
  }

  /// All stored facts currently at [tier], oldest first.
  List<MemoryFact> loadByTier(MemoryTier tier) =>
      [for (final fact in loadFacts()) if (fact.tier == tier) fact];

  /// Case-insensitive comparison key: trimmed with whitespace collapsed.
  static String normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Keeps at most [maxFacts] facts (PHASE 47): the cap applies to the
  /// total, core entries included, but core entries are exempt from
  /// age-based pruning — the oldest non-core facts are dropped first. Only
  /// when the survivors still overflow (an all-core store) does the hard
  /// cap win and the oldest entries fall out regardless of tier.
  List<MemoryFact> _cap(List<MemoryFact> facts) {
    if (facts.length <= maxFacts) return facts;
    final overflow = facts.length - maxFacts;
    final kept = <MemoryFact>[];
    var dropped = 0;
    for (final fact in facts) {
      if (dropped < overflow && fact.tier != MemoryTier.core) {
        dropped += 1;
        continue;
      }
      kept.add(fact);
    }
    return kept.length > maxFacts
        ? kept.sublist(kept.length - maxFacts)
        : kept;
  }

  Future<void> _save(List<MemoryFact> facts) => _prefs.setString(
        storageKey,
        jsonEncode([for (final fact in _cap(facts)) fact.toJson()]),
      );
}
