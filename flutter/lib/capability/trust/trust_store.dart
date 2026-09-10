import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trust_score.dart';

/// PHASE 4 (v3.0 §26): per-capability historical trust. Every capability
/// use records success/failure; the router adds a trust bonus to scoring.
/// Persistence mirrors MemoryStore: SharedPreferences JSON map keyed by
/// capability id, corrupt-payload fallback, cap 200.
class TrustStore {
  TrustStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'shelly.capability.trust';

  /// Maximum tracked capabilities; oldest-by-first-seen evicted.
  static const int maxEntries = 200;

  static const _kUses = 'uses';
  static const _kSuccesses = 'successes';
  static const _kFailures = 'failures';

  /// Records one capability use. Creates the entry on first sight.
  void record(String capabilityId, {required bool ok}) {
    final all = _readAll();
    final entry = all[capabilityId] ?? const <String, int>{};
    final uses = (entry[_kUses] ?? 0) + 1;
    all[capabilityId] = {
      _kUses: uses,
      _kSuccesses: (entry[_kSuccesses] ?? 0) + (ok ? 1 : 0),
      _kFailures: (entry[_kFailures] ?? 0) + (ok ? 0 : 1),
    };
    _writeAll(all);
  }

  /// The score for [capabilityId], or a zero-score when unknown.
  TrustScore scoreFor(String capabilityId) {
    final entry = _readAll()[capabilityId];
    if (entry == null) return const TrustScore();
    return TrustScore(
      uses: entry[_kUses] ?? 0,
      successes: entry[_kSuccesses] ?? 0,
      failures: entry[_kFailures] ?? 0,
    );
  }

  /// All tracked capabilities.
  Map<String, TrustScore> all() {
    final result = <String, TrustScore>{};
    _readAll().forEach((id, entry) {
      result[id] = TrustScore(
        uses: entry[_kUses] ?? 0,
        successes: entry[_kSuccesses] ?? 0,
        failures: entry[_kFailures] ?? 0,
      );
    });
    return result;
  }

  /// Removes one capability's trust history.
  void delete(String capabilityId) {
    final all = _readAll();
    if (all.remove(capabilityId) == null) return;
    _writeAll(all);
  }

  // ---- persistence -------------------------------------------------------

  Map<String, Map<String, int>> _readAll() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, Map<String, int>>{};
      decoded.forEach((id, value) {
        if (value is! Map<String, dynamic>) return;
        result[id] = {
          _kUses: (value[_kUses] as num?)?.toInt() ?? 0,
          _kSuccesses: (value[_kSuccesses] as num?)?.toInt() ?? 0,
          _kFailures: (value[_kFailures] as num?)?.toInt() ?? 0,
        };
      });
      return result;
    } on FormatException {
      return {};
    } catch (_) {
      // Corrupt payload: start fresh rather than crash.
      return {};
    }
  }

  void _writeAll(Map<String, Map<String, int>> all) {
    // Cap: keep the newest 200 entries by insertion order. A re-record of an
    // existing key refreshes its position, so hot capabilities survive.
    final capped = Map.fromEntries(
      all.entries.length > maxEntries
          ? all.entries.skip(all.entries.length - maxEntries)
          : all.entries,
    );
    _prefs.setString(_key, jsonEncode(capped));
  }
}

/// Provider consistent with the other store providers.
final trustStoreProvider = FutureProvider<TrustStore>((ref) async {
  return TrustStore(await SharedPreferences.getInstance());
});
