/// One entry in the Hermes knowledge ledger (V2.0 PHASE 06). Plain data,
/// plain-text persistence — no vector database anywhere in Hermes.
class KnowledgeEntry {
  KnowledgeEntry({
    required this.id,
    required this.content,
    this.category = 'lesson',
    DateTime? createdAt,
    DateTime? lastTriggeredAt,
    this.frequency = 0,
    this.source = 'agent',
    this.project = '',
  })  : createdAt = createdAt ?? DateTime.now(),
        lastTriggeredAt = lastTriggeredAt ?? DateTime.now();

  final String id;
  final String content;

  /// Coarse bucket: lesson / preference / fact / pattern…
  final String category;
  final DateTime createdAt;
  final DateTime lastTriggeredAt;

  /// How often recall() surfaced this entry — the core forgetting signal.
  int frequency;

  /// Where it came from: manual / agent / reflection.
  final String source;

  /// Owning project name; empty string means global.
  final String project;

  KnowledgeEntry copyWith({
    DateTime? lastTriggeredAt,
    int? frequency,
  }) =>
      KnowledgeEntry(
        id: id,
        content: content,
        category: category,
        createdAt: createdAt,
        lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
        frequency: frequency ?? this.frequency,
        source: source,
        project: project,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'category': category,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastTriggeredAt': lastTriggeredAt.millisecondsSinceEpoch,
        'frequency': frequency,
        'source': source,
        'project': project,
      };

  static KnowledgeEntry fromJson(Map<String, dynamic> json) => KnowledgeEntry(
        id: json['id'] as String? ?? 'k-unknown',
        content: json['content'] as String? ?? '',
        category: json['category'] as String? ?? 'lesson',
        createdAt: _millis(json['createdAt']),
        lastTriggeredAt: _millis(json['lastTriggeredAt']),
        frequency: json['frequency'] as int? ?? 0,
        source: json['source'] as String? ?? 'agent',
        project: json['project'] as String? ?? '',
      );

  static DateTime _millis(dynamic value) => value is int
      ? DateTime.fromMillisecondsSinceEpoch(value)
      : DateTime.now();
}

/// Rough token estimate: CJK chars ≈ 1 token each, other text ≈ 1 token
/// per 4 characters. Good enough for ledger budgets, not for billing.
int estimateTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final rune in text.runes) {
    if (rune >= 0x2E80) {
      cjk += 1;
    } else {
      other += 1;
    }
  }
  return cjk + (other / 4).ceil();
}

/// Normalizes content for duplicate detection: whitespace and punctuation
/// collapsed, casefolded.
String normalizeForDedupe(String content) => content
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'[^\w\u4e00-\u9fff ]'), '')
    .trim();

/// Keyword tokens for recall scoring: whitespace words plus individual CJK
/// characters, so Chinese and English tasks match uniformly.
Set<String> tokenize(String text) {
  final tokens = <String>{};
  final splitPattern = RegExp(r"""[\s,.;:!?"'()\[\]{}]+""");
  for (final word in text.toLowerCase().split(splitPattern)) {
    if (word.isEmpty) continue;
    tokens.add(word);
    final runes = word.runes.toList();
    var hasCjk = false;
    for (final rune in runes) {
      if (rune >= 0x2E80) {
        hasCjk = true;
        tokens.add(String.fromCharCode(rune));
      }
    }
    if (!hasCjk && word.length > 3) tokens.add(word);
  }
  return tokens;
}
