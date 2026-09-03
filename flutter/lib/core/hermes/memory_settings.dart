/// User-tunable Hermes memory knobs (V2.1 PHASE 26). Defaults raise the
/// original hard-coded ledger budget 8x (2000 -> 16000 tokens); every
/// value is clamped so a corrupted or extreme prefs file can't wedge the
/// memory system.
class MemorySettings {
  const MemorySettings({
    this.maxLedgerTokens = 16000,
    this.activeDays = 14,
    this.coolingDays = 90,
    this.frequencyFloor = 3,
    this.maxAutoEntries = 300,
    this.recallEntries = 8,
    this.recallTokens = 1200,
  });

  /// Total token budget of the knowledge ledger (forgetting target).
  final int maxLedgerTokens;

  /// Entries recalled within this window are active.
  final int activeDays;

  /// Entries last recalled within this window are cooling.
  final int coolingDays;

  /// Frequently-triggered knowledge never expires on age alone.
  final int frequencyFloor;

  /// Upper bound on auto-captured lessons before capture pauses.
  final int maxAutoEntries;

  /// Entries injected into context per recall.
  final int recallEntries;

  /// Token budget of a single recall injection (separate from storage).
  final int recallTokens;

  MemorySettings copyWith({
    int? maxLedgerTokens,
    int? activeDays,
    int? coolingDays,
    int? frequencyFloor,
    int? maxAutoEntries,
    int? recallEntries,
    int? recallTokens,
  }) =>
      MemorySettings(
        maxLedgerTokens: maxLedgerTokens ?? this.maxLedgerTokens,
        activeDays: activeDays ?? this.activeDays,
        coolingDays: coolingDays ?? this.coolingDays,
        frequencyFloor: frequencyFloor ?? this.frequencyFloor,
        maxAutoEntries: maxAutoEntries ?? this.maxAutoEntries,
        recallEntries: recallEntries ?? this.recallEntries,
        recallTokens: recallTokens ?? this.recallTokens,
      );

  Map<String, dynamic> toJson() => {
        'maxLedgerTokens': maxLedgerTokens,
        'activeDays': activeDays,
        'coolingDays': coolingDays,
        'frequencyFloor': frequencyFloor,
        'maxAutoEntries': maxAutoEntries,
        'recallEntries': recallEntries,
        'recallTokens': recallTokens,
      };

  static MemorySettings fromJson(Map<String, dynamic> json) {
    // Out-of-range values clamp to the boundary; wrong-typed ones fall
    // back to the default.
    int read(String key, int min, int max, int fallback) {
      final raw = json[key];
      if (raw is! int) return fallback;
      return raw.clamp(min, max);
    }

    return MemorySettings(
      maxLedgerTokens:
          read('maxLedgerTokens', 500, 200000, const MemorySettings().maxLedgerTokens),
      activeDays: read('activeDays', 1, 365, const MemorySettings().activeDays),
      coolingDays:
          read('coolingDays', 1, 365, const MemorySettings().coolingDays),
      frequencyFloor:
          read('frequencyFloor', 1, 50, const MemorySettings().frequencyFloor),
      maxAutoEntries:
          read('maxAutoEntries', 10, 2000, const MemorySettings().maxAutoEntries),
      recallEntries:
          read('recallEntries', 1, 50, const MemorySettings().recallEntries),
      recallTokens:
          read('recallTokens', 100, 16000, const MemorySettings().recallTokens),
    );
  }
}
