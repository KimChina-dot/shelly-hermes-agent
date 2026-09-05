import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One recorded model round: the model that served it, the token split and
/// when it happened. Entries live in a single JSON list under
/// SharedPreferences; retention is bounded by [UsageStatsStore.maxEntries]
/// and [UsageStatsStore.retention].
class UsageEntry {
  const UsageEntry({
    required this.modelId,
    required this.promptTokens,
    required this.completionTokens,
    required this.at,
  });

  final String modelId;
  final int promptTokens;
  final int completionTokens;
  final DateTime at;

  int get totalTokens => promptTokens + completionTokens;

  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'at': at.toIso8601String(),
      };

  static UsageEntry fromJson(Map<String, dynamic> json) => UsageEntry(
        modelId: json['modelId'] as String? ?? '',
        promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
        completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
        at: json['at'] is String
            ? DateTime.tryParse(json['at'] as String) ?? DateTime.now()
            : DateTime.now(),
      );

  @override
  bool operator ==(Object other) =>
      other is UsageEntry &&
      other.modelId == modelId &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.at == at;

  @override
  int get hashCode => Object.hash(modelId, promptTokens, completionTokens, at);
}

/// Aggregated token totals shared by the per-model and per-day views.
class UsageTotals {
  const UsageTotals({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.rounds = 0,
  });

  final int promptTokens;
  final int completionTokens;

  /// How many recorded rounds the bucket aggregates.
  final int rounds;

  int get totalTokens => promptTokens + completionTokens;

  UsageTotals add(UsageEntry entry) => UsageTotals(
        promptTokens: promptTokens + entry.promptTokens,
        completionTokens: completionTokens + entry.completionTokens,
        rounds: rounds + 1,
      );

  @override
  bool operator ==(Object other) =>
      other is UsageTotals &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.rounds == rounds;

  @override
  int get hashCode => Object.hash(promptTokens, completionTokens, rounds);
}

/// Local token usage statistics (PHASE 40). Every completed model round is
/// appended to a JSON list in SharedPreferences so the profile page can
/// show totals without any network round-trip. Records older than 30 days
/// are pruned and the list is capped to keep the payload small.
class UsageStatsStore {
  UsageStatsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _statsKey = 'shelly.usage.stats';

  /// Entries older than this never survive a persist.
  static const Duration retention = Duration(days: 30);

  /// Hard cap on stored entries; the newest ones win.
  static const int maxEntries = 1000;

  /// Appends one round, prunes stale/overflowing entries and persists.
  /// An explicit [at] is for tests; production stamps the current time.
  Future<void> recordUsage({
    required String modelId,
    required int promptTokens,
    required int completionTokens,
    DateTime? at,
  }) async {
    final reference = DateTime.now();
    final entry = UsageEntry(
      modelId: modelId,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      at: at ?? reference,
    );
    final entries = [...loadEntries(), entry];
    await _save(_prune(entries, reference: reference));
  }

  /// All stored entries, oldest first.
  List<UsageEntry> loadEntries() {
    final raw = _prefs.getString(_statsKey);
    if (raw == null) return const [];
    try {
      return [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry is Map<String, dynamic>) UsageEntry.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Token totals per model id, newest-independent plain sums over the
  /// retained window.
  Map<String, UsageTotals> totalsByModel() {
    final totals = <String, UsageTotals>{};
    for (final entry in loadEntries()) {
      totals[entry.modelId] = (totals[entry.modelId] ?? const UsageTotals())
          .add(entry);
    }
    return totals;
  }

  /// Token totals keyed by calendar day (`yyyy-MM-dd`, local time).
  Map<String, UsageTotals> totalsByDay() {
    final totals = <String, UsageTotals>{};
    for (final entry in loadEntries()) {
      final day =
          '${entry.at.year.toString().padLeft(4, '0')}-'
          '${entry.at.month.toString().padLeft(2, '0')}-'
          '${entry.at.day.toString().padLeft(2, '0')}';
      totals[day] = (totals[day] ?? const UsageTotals()).add(entry);
    }
    return totals;
  }

  /// Sum over every retained entry.
  UsageTotals totals() {
    var totals = const UsageTotals();
    for (final entry in loadEntries()) {
      totals = totals.add(entry);
    }
    return totals;
  }

  /// Drops entries past the retention window, then the oldest overflow past
  /// [maxEntries].
  List<UsageEntry> _prune(List<UsageEntry> entries, {required DateTime reference}) {
    final cutoff = reference.subtract(retention);
    final fresh = entries.where((entry) => entry.at.isAfter(cutoff)).toList();
    return fresh.length > maxEntries
        ? fresh.sublist(fresh.length - maxEntries)
        : fresh;
  }

  Future<void> _save(List<UsageEntry> entries) => _prefs.setString(
        _statsKey,
        jsonEncode([for (final entry in entries) entry.toJson()]),
      );
}

/// Reactive access for the profile page; the chat session reads the same
/// store per round via `read(usageStatsProvider.future)`.
final usageStatsProvider = FutureProvider<UsageStatsStore>((ref) async {
  return UsageStatsStore(await SharedPreferences.getInstance());
});
