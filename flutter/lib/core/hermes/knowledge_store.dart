import 'dart:convert';

import '../tools/workspace.dart';
import 'forgetting.dart';
import 'knowledge.dart';

/// Durable Hermes ledger (PHASE 06): one JSONL line per entry, kept as
/// plain text in the workspace. The Markdown twin (`.shelly_knowledge.md`)
/// is a human-readable projection written alongside the JSONL — the JSONL
/// file remains the source of truth so parsing never depends on prose.
class HermesKnowledgeStore {
  HermesKnowledgeStore({
    required this.workspace,
    this.project = '',
    this.global = false,
    this.maxRecallEntries = 5,
    this.maxRecallTokens = 400,
  });

  final Workspace workspace;

  /// Project scope key; entries recorded here carry it for filtering.
  final String project;

  /// True when this store is the global ledger rather than a
  /// per-project one (different file in the same workspace).
  final bool global;

  final int maxRecallEntries;
  final int maxRecallTokens;

  String get jsonlPath => global
      ? '.shelly/knowledge.global.jsonl'
      : '.shelly/knowledge.jsonl';

  String get markdownPath => global
      ? '.shelly/knowledge.global.md'
      : '.shelly_knowledge.md';

  Future<List<KnowledgeEntry>> loadAll() async {
    final raw = await workspace.readFile(jsonlPath);
    if (raw == null || raw.trim().isEmpty) return [];
    final entries = <KnowledgeEntry>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          entries.add(KnowledgeEntry.fromJson(decoded));
        }
      } on FormatException {
        // A corrupt line must not take the whole ledger down.
        continue;
      }
    }
    return entries;
  }

  Future<void> append(KnowledgeEntry entry) async {
    final entries = await loadAll();
    await saveAll([...entries, entry]);
  }

  /// Rewrites the ledger — used by reflection and forgetting.
  Future<void> saveAll(List<KnowledgeEntry> entries) async {
    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.writeln(jsonEncode(entry.toJson()));
    }
    await workspace.writeFile(jsonlPath, buffer.toString());
    await _writeMarkdownProjection();
  }

  /// Recalls entries relevant to [task]: keyword overlap scoring over the
  /// union of project + global ledgers (this store's scope only). Matching
  /// entries get their trigger counters bumped — the forgetting signal.
  Future<List<String>> recall(String task) async {
    final entries = await loadAll();
    if (entries.isEmpty) return [];
    final taskTokens = tokenize(task);
    final scored = <(KnowledgeEntry, int)>[];
    for (final entry in entries) {
      final score = tokenize('${entry.content} ${entry.category}')
          .intersection(taskTokens)
          .length;
      if (score > 0) scored.add((entry, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final recalled = <KnowledgeEntry>[];
    var tokens = 0;
    for (final (entry, _) in scored) {
      final cost = estimateTokens(entry.content);
      if (recalled.isNotEmpty && tokens + cost > maxRecallTokens) break;
      recalled.add(entry);
      tokens += cost;
      if (recalled.length >= maxRecallEntries) break;
    }
    if (recalled.isEmpty) return [];
    await _markTriggered(recalled);
    return [
      for (final entry in recalled) entry.content,
    ];
  }

  Future<void> _markTriggered(List<KnowledgeEntry> recalled) async {
    final entries = await loadAll();
    final triggeredIds = recalled.map((e) => e.id).toSet();
    final updated = [
      for (final entry in entries)
        if (triggeredIds.contains(entry.id))
          entry.copyWith(
            frequency: entry.frequency + 1,
            lastTriggeredAt: DateTime.now(),
          )
        else
          entry,
    ];
    await saveAll(updated);
  }

  /// Forgetting pass (PHASE 10): evaluates vitality and drops entries
  /// beyond the ledger token budget, coldest first.
  Future<ForgettingReport> applyForgetting({
    ForgettingPolicy policy = const ForgettingPolicy(),
  }) async {
    final entries = await loadAll();
    final report = forget(entries, policy: policy);
    if (report.droppedIds.isNotEmpty) {
      await saveAll(report.kept);
    }
    return report;
  }

  /// Human-readable projection for inspection and manual curation.
  Future<void> _writeMarkdownProjection() async {
    final entries = await loadAll();
    final buffer = StringBuffer('# Shelly Hermes 知识账本\n\n');
    if (entries.isEmpty) {
      buffer.writeln('(空)\n');
    }
    for (final entry in entries) {
      buffer.writeln(
        '- [${entry.id}] ${entry.category} · freq=${entry.frequency}'
        ' · source=${entry.source}'
        '${entry.project.isEmpty ? '' : ' · project=${entry.project}'}',
      );
      buffer.writeln('  ${entry.content.replaceAll('\n', ' ')}');
    }
    await workspace.writeFile(markdownPath, buffer.toString());
  }
}
