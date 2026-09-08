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

/// Outcome of one [MemoryStore.importJson] run (PHASE 50): how many facts
/// were written, how many valid entries were dropped because their text
/// already existed, and how many entries could not become facts at all.
class ImportReport {
  const ImportReport({
    required this.imported,
    required this.skippedDuplicates,
    required this.invalidEntries,
  });

  /// Facts that were actually added to the store.
  final int imported;

  /// Valid entries skipped because their normalized text already existed
  /// (merge mode; existing facts win).
  final int skippedDuplicates;

  /// Entries that were not usable facts (wrong shape or empty text); they
  /// are skipped and only counted.
  final int invalidEntries;

  @override
  bool operator ==(Object other) =>
      other is ImportReport &&
      other.imported == imported &&
      other.skippedDuplicates == skippedDuplicates &&
      other.invalidEntries == invalidEntries;

  @override
  int get hashCode =>
      Object.hash(imported, skippedDuplicates, invalidEntries);

  @override
  String toString() =>
      'ImportReport(imported: $imported, '
      'skippedDuplicates: $skippedDuplicates, invalidEntries: $invalidEntries)';
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

  /// Envelope version stamped by [exportJson] (PHASE 50); lets future
  /// formats be detected and migrated on import.
  static const int exportVersion = 1;

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

  /// Renders the whole fact list as a versioned JSON backup (PHASE 50):
  /// an envelope `{version, exportedAt, count, facts}` whose per-fact
  /// entries use the exact same shape as on-disk persistence, so a backup
  /// file round-trips through [importJson] without any conversion.
  String exportJson({DateTime? exportedAt}) {
    final facts = loadFacts();
    return const JsonEncoder.withIndent('  ').convert({
      'version': exportVersion,
      'exportedAt':
          (exportedAt ?? DateTime.now()).toIso8601String(),
      'count': facts.length,
      'facts': [for (final fact in facts) fact.toJson()],
    });
  }

  /// Restores facts from an [exportJson] backup (PHASE 50). Replace mode
  /// (the default) wipes the store and loads exactly what the file holds;
  /// merge mode keeps existing facts and adds only the entries whose
  /// normalized text is new (existing facts win, so their tier and
  /// timestamps are untouched). Entries that cannot become facts (wrong
  /// shape, missing id or blank text) are counted in
  /// [ImportReport.invalidEntries] and skipped; structurally corrupt JSON
  /// (bad syntax, wrong envelope) throws [FormatException] for the caller
  /// to surface.
  Future<ImportReport> importJson(
    String json, {
    bool merge = false,
  }) async {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('memory backup: envelope must be an object');
    }
    final rawFacts = decoded['facts'];
    if (rawFacts is! List<dynamic>) {
      throw const FormatException("memory backup: missing 'facts' list");
    }
    final imported = <MemoryFact>[];
    var invalid = 0;
    for (final entry in rawFacts) {
      if (entry is! Map<String, dynamic>) {
        invalid += 1;
        continue;
      }
      final fact = MemoryFact.fromJson(entry);
      // A fact without an id or with blank text is meaningless; count it
      // as invalid in both modes instead of silently storing it.
      if (fact.id.isEmpty || normalize(fact.text).isEmpty) {
        invalid += 1;
        continue;
      }
      imported.add(fact);
    }
    if (merge) {
      final facts = loadFacts();
      final existingTexts = {
        for (final fact in facts) normalize(fact.text),
      };
      final additions = <MemoryFact>[];
      var duplicates = 0;
      for (final fact in imported) {
        final key = normalize(fact.text);
        if (existingTexts.contains(key)) {
          duplicates += 1;
          continue;
        }
        existingTexts.add(key);
        additions.add(fact);
      }
      if (additions.isNotEmpty) {
        await _save([...facts, ...additions]);
      }
      return ImportReport(
        imported: additions.length,
        skippedDuplicates: duplicates,
        invalidEntries: invalid,
      );
    }
    await _save(imported);
    return ImportReport(
      imported: imported.length,
      skippedDuplicates: 0,
      invalidEntries: invalid,
    );
  }


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
