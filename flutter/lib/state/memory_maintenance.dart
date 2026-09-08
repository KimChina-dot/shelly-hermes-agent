// Named constructor params are kept public-named for call-site readability;
// the initializing-formal rewrite would force private names at call sites.
// ignore_for_file: prefer_initializing_formals
import 'package:shared_preferences/shared_preferences.dart';

import '../core/memory/consolidation.dart'
    show ConsolidationReport, MemoryConsolidator;
import '../core/memory/memory_store.dart' show MemoryStore;

/// Sleep-time memory maintenance trigger (PHASE 47): decides WHEN the
/// [MemoryConsolidator] pass runs so the existing wake flow (shell init,
/// app resume — the periodic worker already wakes the app) can keep memory
/// tidy automatically, at most once per day, entirely off the chat loop.
///
/// The throttle mirrors [UpdateCheckService]: the last run is stamped as
/// epoch millis under SharedPreferences and automatic triggers inside the
/// window skip the pass entirely; `force: true` (the manual 整理记忆
/// button) bypasses it. The stamp is written BEFORE the pass runs so a slow
/// consolidation can never overlap the next wake trigger, and every failure
/// is swallowed — maintenance must never break the app.
class MemoryMaintenanceService {
  MemoryMaintenanceService({
    SharedPreferences? prefs,
    DateTime Function()? clock,
  })  : _injectedPrefs = prefs,
        _now = clock ?? DateTime.now;

  /// Optional prefs injected for tests; production resolves the singleton
  /// lazily so a degraded host surfaces as a swallowed failure, never a
  /// constructor throw.
  final SharedPreferences? _injectedPrefs;

  /// Injectable clock; production stamps [DateTime.now].
  final DateTime Function() _now;

  /// SharedPreferences key storing the last maintenance run (epoch millis).
  static const lastRunKey = 'shelly.memory.maintenance.lastRun';

  /// Prefs key holding the recall-tier aging window (days).
  static const recallAgeDaysKey = 'shelly.memory.recallAgeDays';

  /// Prefs key holding the archival-tier capacity (facts).
  static const archivalCapKey = 'shelly.memory.archivalCap';

  /// Default aging window for recall facts, mirroring the consolidator.
  static const defaultRecallAgeDays = 45;

  /// Default archival cap, mirroring the consolidator.
  static const defaultArchivalCap = 300;

  /// Automatic triggers inside this window skip the pass; `force: true`
  /// bypasses it (manual runs never wait a day).
  static const minInterval = Duration(hours: 20);

  /// Runs the consolidation pass over [store] when the daily throttle
  /// allows it. Returns the pass report, or null when skipped (throttled,
  /// store unavailable) or when anything failed — maintenance is
  /// best-effort by contract and never throws.
  Future<ConsolidationReport?> runIfNeeded(
    MemoryStore? store, {
    bool force = false,
  }) async {
    try {
      if (store == null) return null;
      final prefs = await _resolvePrefs();
      final now = _now();
      if (!force && _ranRecently(prefs, now)) return null;
      // Stamp BEFORE running: a slow pass cannot overlap the next wake
      // trigger, and a crash mid-pass only costs one skipped day.
      await prefs.setInt(lastRunKey, now.millisecondsSinceEpoch);
      return await MemoryConsolidator(
        clock: _now,
        recallAgeDays: _readInt(prefs, recallAgeDaysKey, defaultRecallAgeDays),
        archivalCap: _readInt(prefs, archivalCapKey, defaultArchivalCap),
      ).consolidate(store);
    } catch (_) {
      // Maintenance must never introduce a failure.
      return null;
    }
  }

  /// Whether a maintenance pass started within [minInterval] before [now].
  bool _ranRecently(SharedPreferences prefs, DateTime now) {
    final last = prefs.getInt(lastRunKey);
    if (last == null) return false;
    return now.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
        minInterval;
  }

  /// The injected prefs (tests) or the shared singleton (production);
  /// throws when SharedPreferences is unavailable so the caller swallows it.
  Future<SharedPreferences> _resolvePrefs() async =>
      _injectedPrefs ?? await SharedPreferences.getInstance();

  /// Lenient int read: missing keys fall back to [fallback] and wrong-typed
  /// values (legacy or hand-edited prefs) fall back instead of throwing.
  static int _readInt(SharedPreferences prefs, String key, int fallback) {
    try {
      final value = prefs.getInt(key);
      return value ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
