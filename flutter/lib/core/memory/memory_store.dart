import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One durable fact the assistant learned about the user (PHASE 41): a
/// short preference or stable piece of personal context, captured from a
/// finished conversation round.
class MemoryFact {
  const MemoryFact({
    required this.id,
    required this.text,
    required this.createdAt,
    this.sourceConversationId,
  });

  final String id;
  final String text;
  final DateTime createdAt;

  /// Conversation the fact was extracted from; informational only.
  final String? sourceConversationId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        if (sourceConversationId != null)
          'sourceConversationId': sourceConversationId,
      };

  static MemoryFact fromJson(Map<String, dynamic> json) => MemoryFact(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        createdAt: json['createdAt'] is String
            ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        sourceConversationId: json['sourceConversationId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is MemoryFact &&
      other.id == id &&
      other.text == text &&
      other.createdAt == createdAt &&
      other.sourceConversationId == sourceConversationId;

  @override
  int get hashCode => Object.hash(id, text, createdAt, sourceConversationId);
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

  /// Case-insensitive comparison key: trimmed with whitespace collapsed.
  static String normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Keeps at most [maxFacts] facts, dropping the oldest overflow.
  List<MemoryFact> _cap(List<MemoryFact> facts) => facts.length > maxFacts
      ? facts.sublist(facts.length - maxFacts)
      : facts;

  Future<void> _save(List<MemoryFact> facts) => _prefs.setString(
        storageKey,
        jsonEncode([for (final fact in _cap(facts)) fact.toJson()]),
      );
}
