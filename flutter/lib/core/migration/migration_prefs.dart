import 'package:shared_preferences/shared_preferences.dart';

/// Thin, injectable persistence port for the v3.0 migration pipeline
/// (docs/audit/V3_MIGRATION_PLAN.md §1, PHASE 3 — "build only").
///
/// [MigrationManager] never depends on [SharedPreferences] directly: the
/// production adapter is [SharedPreferencesMigrationPrefs] and tests drive
/// an in-memory fake, so the five stages (backup → validate → migrate →
/// verify → rollback) run identically under `flutter test` and on the host.
abstract interface class MigrationPrefs {
  /// Every key currently persisted, regardless of value type.
  Set<String> getKeys();

  /// Raw typed read (String, bool, int, double or `List<String>`) used for
  /// faithful value snapshots. Null when the key does not exist.
  Object? get(String key);

  /// String read for JSON payloads; null when absent or not a string.
  String? getString(String key);

  /// Typed write dispatched on the runtime type of [value] — one of
  /// String, bool, int, double or `List<String>`. A null value removes the
  /// key. Implementations may throw on unsupported types; the migration
  /// manager treats any throw as a stage failure (never crashes startup).
  Future<void> set(String key, Object? value);

  /// Plain string write (JSON payloads, raw scalars).
  Future<void> setString(String key, String value);

  /// Removes the key when present; a no-op otherwise.
  Future<void> remove(String key);
}

/// Production [MigrationPrefs] over [SharedPreferences].
class SharedPreferencesMigrationPrefs implements MigrationPrefs {
  SharedPreferencesMigrationPrefs(this._prefs);

  final SharedPreferences _prefs;

  @override
  Set<String> getKeys() => _prefs.getKeys();

  @override
  Object? get(String key) => _prefs.get(key);

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> set(String key, Object? value) {
    if (value == null) return remove(key);
    if (value is String) return _prefs.setString(key, value);
    if (value is bool) return _prefs.setBool(key, value);
    if (value is int) return _prefs.setInt(key, value);
    if (value is double) return _prefs.setDouble(key, value);
    if (value is List<String>) return _prefs.setStringList(key, value);
    throw ArgumentError.value(
      value,
      'value',
      'Unsupported prefs value type for key "$key"',
    );
  }

  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
