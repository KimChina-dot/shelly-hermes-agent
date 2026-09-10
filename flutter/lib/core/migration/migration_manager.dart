import 'dart:convert';

import 'migration_keys.dart';
import 'migration_prefs.dart';

/// Where a migration run stands after [MigrationManager.run].
enum MigrationStage { backup, validate, migrate, verify, rollback }

/// Outcome of one executed stage.
enum MigrationPhaseStatus { ok, skipped, failed }

/// One stage line in the structured [MigrationResult] report.
class MigrationPhaseReport {
  const MigrationPhaseReport(this.stage, this.status, [this.detail]);

  final MigrationStage stage;
  final MigrationPhaseStatus status;

  /// Human-readable note: skip reason or failure cause.
  final String? detail;

  @override
  String toString() =>
      '$stage:${status.name}${detail == null ? '' : '($detail)'}';
}

/// A validation finding for one key (bad JSON, wrong shape, …).
class MigrationKeyIssue {
  const MigrationKeyIssue(this.key, this.reason);

  final String key;
  final String reason;

  @override
  String toString() => '$key: $reason';
}

/// Count + checksum summary of one persisted value. The verify stage
/// compares digests recomputed after migration against the digests the
/// backup stage recorded — counts must match for the verify-critical
/// families (conversations / memory facts / scheduled tasks /
/// checkpoints, V3_MIGRATION_PLAN.md §1 verify).
class MigrationDigest {
  const MigrationDigest({
    required this.itemCount,
    required this.checksum,
  });

  /// Number of items the value carries: list length for JSON arrays,
  /// `messages.length` for checkpoints, 1 for single records and scalars.
  final int itemCount;

  /// Order-insensitive FNV-1a checksum over the canonical JSON encoding.
  final int checksum;

  Map<String, Object> toJson() => {'count': itemCount, 'checksum': checksum};

  static MigrationDigest? fromJson(Object? json) => json is Map<String, dynamic>
      ? MigrationDigest(
          itemCount: (json['count'] as num?)?.toInt() ?? 0,
          checksum: (json['checksum'] as num?)?.toInt() ?? 0,
        )
      : null;

  @override
  bool operator ==(Object other) =>
      other is MigrationDigest &&
      other.itemCount == itemCount &&
      other.checksum == checksum;

  @override
  int get hashCode => Object.hash(itemCount, checksum);
}

/// Decoded backup envelope stored under [kMigrationBackupKey].
class MigrationBackup {
  MigrationBackup({
    required this.schemaVersion,
    required this.backupAt,
    required this.entries,
    required this.digests,
  });

  final int schemaVersion;

  /// UTC timestamp taken through the injectable clock.
  final DateTime backupAt;

  /// Original key → raw persisted value, copied verbatim (String/bool/int/
  /// double/`List<String>`). JSON payloads stay untouched strings so even a
  /// corrupt payload survives the round-trip byte-for-byte.
  final Map<String, Object?> entries;

  /// Original key → digest recorded at backup time; the verify criterion.
  final Map<String, MigrationDigest> digests;

  Map<String, Object> toJson() => {
        'schemaVersion': schemaVersion,
        'backupAt': backupAt.toIso8601String(),
        'entries': entries,
        'digests': {
          for (final e in digests.entries) e.key: e.value.toJson(),
        },
      };
}

/// Injectable sink for non-fatal findings (validate failures, backup
/// reuse, …). Default is silent; production can wire it to the crash log
/// (core/crash/crash_log_store.dart) per V3_MIGRATION_PLAN.md §1.
typedef MigrationLogger = void Function(String message);
void _silentLogger(String message) {}

/// Shape transform applied by the migrate stage: receives the original key
/// and its raw persisted value, returns the JSON payload to store under
/// `shelly.v3.<key>`. The default envelope keeps the original verbatim
/// under `'value'`; custom transforms (plugged in at the PHASE 8 cutover,
/// e.g. checkpoint version 1→2) must keep that contract — verify digests
/// the `'value'` projection against the backup record.
typedef MigrationValueTransform = Map<String, Object?> Function(
  String key,
  Object? rawValue,
);

Map<String, Object?> defaultMigrationTransform(String key, Object? rawValue) =>
    {'schemaVersion': 3, 'source': key, 'value': rawValue};

/// Result of [MigrationManager.run]. [success] means the pipeline ran to a
/// verified completion (or was skipped because a previous run completed);
/// [rolledBack] means the verify/migrate safety net restored the
/// pre-migration state. `run()` never throws — every failure lands here.
class MigrationResult {
  const MigrationResult({
    required this.phases,
    required this.backedUpKeys,
    required this.invalidKeys,
    required this.unknownKeys,
    required this.migratedKeys,
    required this.verifyFailures,
    this.skipped = false,
    this.success = false,
    this.rolledBack = false,
    this.reusedBackup = false,
    this.errorMessage,
  });

  /// True when the whole pipeline short-circuited because a previous run
  /// already reached a terminal state (`completed` / `rolledback`).
  final bool skipped;

  /// Verified completion without rollback.
  final bool success;

  /// A failure path executed the rollback stage.
  final bool rolledBack;

  /// True when an existing valid backup was reused instead of overwritten
  /// (idempotency anchor for crash recovery).
  final bool reusedBackup;

  final List<MigrationPhaseReport> phases;
  final List<String> backedUpKeys;
  final List<MigrationKeyIssue> invalidKeys;
  final List<String> unknownKeys;

  /// Source keys that received a `shelly.v3.*` twin.
  final List<String> migratedKeys;
  final List<MigrationKeyIssue> verifyFailures;

  /// First hard failure, if any (backup I/O, unexpected exception, …).
  final String? errorMessage;
}

/// Five-stage SharedPreferences migration engine for v3.0
/// (docs/audit/V3_MIGRATION_PLAN.md §1; key inventory and risk framing in
/// docs/audit/MIGRATION_RISK.md R1).
///
/// Stages:
/// 1. **backup** — snapshots every `shelly.*` source key (excluding the
///    `shelly.migration.*` bookkeeping and `shelly.v3.*` output
///    namespaces) verbatim into the single JSON key
///    `shelly.migration.backup.v3`, stamped with `schemaVersion` and a
///    UTC timestamp, plus the digests verify will later compare against.
///    An existing valid backup is reused, never overwritten — the anchor
///    that keeps a re-run after a crash idempotent.
/// 2. **validate** — per-key jsonDecode + shape assertion against the R1
///    key catalog. Bad keys are logged through the injectable logger and
///    reported, but never abort the run (a corrupt key simply does not
///    get a v3 twin).
/// 3. **migrate** — writes the transformed payload to `shelly.v3.<key>`
///    for every valid source key. Old keys are kept untouched: they are
///    the rollback anchor, and v3 readers fall back to them via compat
///    reads in the worst case.
/// 4. **verify** — recomputes digests from the persisted v3 payloads and
///    from the still-present old keys; any mismatch against the backup
///    record triggers rollback automatically.
/// 5. **rollback** — removes every `shelly.v3.*` output key and rewrites
///    each backup entry to its original key verbatim, then marks
///    `shelly.migration.state=rolledback`. Because migrate never deletes
///    old keys, the store ends byte-identical to the pre-migration state.
///
/// Build-only in this phase (PHASE 3 of the plan): no production caller
/// is wired; main.dart integration happens at the PHASE 8 cutover.
class MigrationManager {
  MigrationManager({
    required this._prefs,
    MigrationLogger? logger,
    DateTime Function()? clock,
    MigrationValueTransform? transform,

    /// Test seam invoked between migrate and verify; production leaves it
    /// null. Used to tamper with persisted state so the verify/rollback
    /// path can be exercised deterministically.
    this._afterMigrateHook,
  })  : _logger = logger ?? _silentLogger,
        _clock = clock ?? DateTime.now,
        _transform = transform ?? defaultMigrationTransform;
  static const int schemaVersion = 3;
  static const String stateCompleted = 'completed';
  static const String stateRolledBack = 'rolledback';
  static const String stateFailed = 'failed';

  final MigrationPrefs _prefs;
  final MigrationLogger _logger;
  final DateTime Function() _clock;
  final MigrationValueTransform _transform;
  final Future<void> Function()? _afterMigrateHook;

  /// Runs the full pipeline. Never throws: every stage failure is caught,
  /// folded into the returned [MigrationResult] and — once anything has
  /// been written — answered with an automatic rollback.
  Future<MigrationResult> run() async {
    // Idempotency guard: a terminal state from a previous run means this
    // run must not touch anything (backup included).
    final priorState = _prefs.getString(kMigrationStateKey);
    if (priorState == stateCompleted || priorState == stateRolledBack) {
      _logger('migration: skipping run, prior state=$priorState');
      return MigrationResult(
        skipped: true,
        success: priorState == stateCompleted,
        phases: [
          for (final stage in MigrationStage.values)
            MigrationPhaseReport(
              stage,
              MigrationPhaseStatus.skipped,
              'prior state=$priorState',
            ),
        ],
        backedUpKeys: const [],
        invalidKeys: const [],
        unknownKeys: const [],
        migratedKeys: const [],
        verifyFailures: const [],
      );
    }

    final phases = <MigrationPhaseReport>[];
    var backedUpKeys = const <String>[];
    var invalidKeys = const <MigrationKeyIssue>[];
    var unknownKeys = const <String>[];
    var migratedKeys = const <String>[];
    var verifyFailures = const <MigrationKeyIssue>[];
    var reusedBackup = false;
    var rolledBack = false;
    String? errorMessage;

    // ---- 1. backup ----------------------------------------------------
    MigrationBackup? backup;
    try {
      final existing = _readExistingBackup();
      if (existing != null) {
        backup = existing;
        reusedBackup = true;
        backedUpKeys = existing.entries.keys.toList()..sort();
        phases.add(const MigrationPhaseReport(
          MigrationStage.backup,
          MigrationPhaseStatus.ok,
          'reused existing backup',
        ));
      } else {
        backup = await _writeBackup();
        backedUpKeys = backup.entries.keys.toList()..sort();
        phases.add(const MigrationPhaseReport(
          MigrationStage.backup,
          MigrationPhaseStatus.ok,
        ));
      }
    } catch (error) {
      phases.add(MigrationPhaseReport(
        MigrationStage.backup,
        MigrationPhaseStatus.failed,
        '$error',
      ));
      await _trySetState(stateFailed);
      return _result(
        phases,
        errorMessage: 'backup failed: $error',
      );
    }
    final snapshot = backup;

    // ---- 2. validate (never aborts the run) ---------------------------
    try {
      final report = _validate(snapshot);
      invalidKeys = report.$1;
      unknownKeys = report.$2;
      phases.add(MigrationPhaseReport(
        MigrationStage.validate,
        MigrationPhaseStatus.ok,
        invalidKeys.isEmpty
            ? null
            : '${invalidKeys.length} invalid key(s), '
                '${unknownKeys.length} unknown key(s)',
      ));
    } catch (error) {
      phases.add(MigrationPhaseReport(
        MigrationStage.validate,
        MigrationPhaseStatus.failed,
        '$error',
      ));
      await _trySetState(stateFailed);
      return _result(phases, errorMessage: 'validate crashed: $error');
    }

    // ---- 3. migrate ----------------------------------------------------
    final invalidKeySet = invalidKeys.map((issue) => issue.key).toSet();
    final migrateableKeys =
        snapshot.entries.keys.where((k) => !invalidKeySet.contains(k)).toList()
          ..sort();
    try {
      migratedKeys = await _migrate(snapshot, migrateableKeys);
      phases.add(MigrationPhaseReport(
        MigrationStage.migrate,
        MigrationPhaseStatus.ok,
        '${migratedKeys.length} key(s)',
      ));
    } catch (error) {
      phases.add(MigrationPhaseReport(
        MigrationStage.migrate,
        MigrationPhaseStatus.failed,
        '$error',
      ));
      rolledBack = await _rollback(snapshot, phases);
      await _trySetState(rolledBack ? stateRolledBack : stateFailed);
      return _result(
        phases,
        invalidKeys: invalidKeys,
        unknownKeys: unknownKeys,
        rolledBack: rolledBack,
        errorMessage: 'migrate failed: $error',
      );
    }

    // Test seam: forge an inconsistent state between migrate and verify.
    final hook = _afterMigrateHook;
    if (hook != null) {
      try {
        await hook();
      } catch (error) {
        _logger('migration: afterMigrateHook threw: $error');
      }
    }

    // ---- 4. verify -----------------------------------------------------
    try {
      verifyFailures = _verify(snapshot, migratedKeys);
      phases.add(MigrationPhaseReport(
        MigrationStage.verify,
        verifyFailures.isEmpty
            ? MigrationPhaseStatus.ok
            : MigrationPhaseStatus.failed,
        verifyFailures.isEmpty
            ? '${migratedKeys.length} key(s) match'
            : '${verifyFailures.length} mismatch(es)',
      ));
    } catch (error) {
      verifyFailures = [MigrationKeyIssue('*', 'verify crashed: $error')];
      phases.add(MigrationPhaseReport(
        MigrationStage.verify,
        MigrationPhaseStatus.failed,
        '$error',
      ));
    }

    if (verifyFailures.isNotEmpty) {
      rolledBack = await _rollback(snapshot, phases);
      await _trySetState(rolledBack ? stateRolledBack : stateFailed);
      return _result(
        phases,
        invalidKeys: invalidKeys,
        unknownKeys: unknownKeys,
        migratedKeys: migratedKeys,
        verifyFailures: verifyFailures,
        rolledBack: rolledBack,
        errorMessage: 'verify failed, rolled back',
      );
    }

    // ---- 5. complete ----------------------------------------------------
    try {
      await _prefs.setString(kMigrationStateKey, stateCompleted);
    } catch (error) {
      errorMessage = 'state write failed: $error';
      _logger('migration: $errorMessage');
    }
    return _result(
      phases,
      backedUpKeys: backedUpKeys,
      invalidKeys: invalidKeys,
      unknownKeys: unknownKeys,
      migratedKeys: migratedKeys,
      reusedBackup: reusedBackup,
      success: errorMessage == null,
      errorMessage: errorMessage,
    );
  }

  MigrationResult _result(
    List<MigrationPhaseReport> phases, {
    List<String> backedUpKeys = const [],
    List<MigrationKeyIssue> invalidKeys = const [],
    List<String> unknownKeys = const [],
    List<String> migratedKeys = const [],
    List<MigrationKeyIssue> verifyFailures = const [],
    bool reusedBackup = false,
    bool success = false,
    bool rolledBack = false,
    String? errorMessage,
  }) =>
      MigrationResult(
        phases: List.unmodifiable(phases),
        backedUpKeys: List.unmodifiable(backedUpKeys),
        invalidKeys: List.unmodifiable(invalidKeys),
        unknownKeys: List.unmodifiable(unknownKeys),
        migratedKeys: List.unmodifiable(migratedKeys),
        verifyFailures: List.unmodifiable(verifyFailures),
        reusedBackup: reusedBackup,
        success: success,
        rolledBack: rolledBack,
        errorMessage: errorMessage,
      );

  Future<void> _trySetState(String value) async {
    try {
      await _prefs.setString(kMigrationStateKey, value);
    } catch (error) {
      _logger('migration: state write failed: $error');
    }
  }

  /// Whether [key] is migration source data: any `shelly.*` key outside
  /// the bookkeeping (`shelly.migration.*`) and output (`shelly.v3.*`)
  /// namespaces.
  bool _isSourceKey(String key) =>
      key.startsWith('shelly.') &&
      !key.startsWith(kMigrationNamespace) &&
      !key.startsWith(kMigratedKeyPrefix);

  /// Backup stage writer: snapshots every source key verbatim, records
  /// per-key digests and persists the envelope.
  Future<MigrationBackup> _writeBackup() async {
    final keys = _prefs.getKeys().where(_isSourceKey).toList()..sort();
    final entries = <String, Object?>{};
    final digests = <String, MigrationDigest>{};
    for (final key in keys) {
      final value = _prefs.get(key);
      if (value == null) continue;
      entries[key] = value;
      digests[key] = digestFor(key, value)!;
    }
    final backup = MigrationBackup(
      schemaVersion: schemaVersion,
      backupAt: _clock().toUtc(),
      entries: entries,
      digests: digests,
    );
    await _prefs.setString(kMigrationBackupKey, jsonEncode(backup.toJson()));
    _logger('migration: backed up ${entries.length} key(s)');
    return backup;
  }

  /// Backup stage idempotency anchor: returns the stored backup only when
  /// it decodes cleanly and matches [schemaVersion]; a corrupt or missing
  /// envelope returns null so the caller re-snapshots (safe: old keys are
  /// always untouched at this point).
  MigrationBackup? _readExistingBackup() {
    final raw = _prefs.getString(kMigrationBackupKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if ((decoded['schemaVersion'] as num?)?.toInt() != schemaVersion) {
        return null;
      }
      final rawEntries = decoded['entries'];
      final rawDigests = decoded['digests'];
      if (rawEntries is! Map<String, dynamic>) return null;
      if (rawDigests is! Map<String, dynamic>) return null;
      final backupAt = DateTime.tryParse(decoded['backupAt'] as String? ?? '');
      if (backupAt == null) return null;
      final digests = <String, MigrationDigest>{};
      for (final entry in rawDigests.entries) {
        final digest = MigrationDigest.fromJson(entry.value);
        if (digest == null) return null;
        digests[entry.key] = digest;
      }
      return MigrationBackup(
        schemaVersion: schemaVersion,
        backupAt: backupAt,
        entries: {
          for (final entry in rawEntries.entries)
            entry.key: _normalizeJsonValue(entry.value),
        },
        digests: digests,
      );
    } catch (error) {
      _logger('migration: existing backup unreadable ($error), re-snapshot');
      return null;
    }
  }

  /// Validate stage: runs the R1 catalog assertions over the backup
  /// snapshot. Returns (invalid keys, unknown keys). Pure — never touches
  /// persistence, never interrupts the caller.
  (List<MigrationKeyIssue>, List<String>) _validate(MigrationBackup backup) {
    final invalid = <MigrationKeyIssue>[];
    final unknown = <String>[];
    for (final key in backup.entries.keys) {
      final spec = migrationSpecForKey(key);
      if (spec == null) {
        unknown.add(key);
        _logger('migration: unknown shelly.* key $key (backed up, '
            'not shape-validated)');
        continue;
      }
      final reason = _validateShape(spec, backup.entries[key]);
      if (reason != null) {
        invalid.add(MigrationKeyIssue(key, reason));
        _logger('migration: invalid key $key — $reason');
      }
    }
    return (invalid, unknown);
  }

  /// Shape assertion for one key against its [MigrationKeySpec]; null when
  /// the value passes.
  String? _validateShape(MigrationKeySpec spec, Object? value) {
    switch (spec.kind) {
      case MigrationValueKind.jsonList:
      case MigrationValueKind.jsonMap:
        if (value is! String) {
          return 'expected a JSON string, found ${value.runtimeType}';
        }
        final Object? decoded;
        try {
          decoded = jsonDecode(value);
        } on FormatException {
          return 'invalid JSON';
        }
        if (spec.kind == MigrationValueKind.jsonList) {
          if (decoded is! List) return 'expected a JSON list';
          for (var i = 0; i < decoded.length; i++) {
            final entry = decoded[i];
            if (entry is! Map) return 'entry $i is not an object';
            for (final field in spec.entryFields) {
              if (!entry.containsKey(field)) {
                return 'entry $i misses "$field"';
              }
            }
          }
        } else {
          if (decoded is! Map) return 'expected a JSON object';
          for (final field in spec.requiredFields) {
            if (!decoded.containsKey(field)) return 'misses "$field"';
          }
        }
        return null;
      case MigrationValueKind.plainString:
        return value is String ? null : 'expected a string';
      case MigrationValueKind.plainBool:
        return value is bool ? null : 'expected a bool';
      case MigrationValueKind.plainInt:
        return value is int ? null : 'expected an int';
      case MigrationValueKind.plainStringList:
        if (value is! List) return 'expected a string list';
        return value.every((e) => e is String) ? null : 'expected strings';
    }
  }

  /// Migrate stage: writes the transformed payload under
  /// `shelly.v3.<key>` for every migrateable source key. Old keys are
  /// intentionally left untouched (rollback anchor).
  Future<List<String>> _migrate(
    MigrationBackup backup,
    List<String> keys,
  ) async {
    final migrated = <String>[];
    for (final key in keys) {
      final payload = _transform(key, backup.entries[key]);
      await _prefs.setString(
        _v3KeyFor(key),
        jsonEncode(payload),
      );
      migrated.add(key);
    }
    return migrated;
  }

  /// Verify stage: recomputes digests and compares them against the
  /// backup record. Checks both directions — every migrated v3 payload
  /// must project back to the original value, and every old key must
  /// still carry its original value.
  List<MigrationKeyIssue> _verify(
    MigrationBackup backup,
    List<String> migratedKeys,
  ) {
    final failures = <MigrationKeyIssue>[];

    // (a) migrated payloads: the `'value'` projection of each `shelly.v3.*`
    // key must digest-match the backup record.
    for (final key in migratedKeys) {
      final v3Key = _v3KeyFor(key);
      final expected = backup.digests[key];
      final raw = _prefs.getString(v3Key);
      if (raw == null) {
        failures.add(MigrationKeyIssue(v3Key, 'missing after migrate'));
        continue;
      }
      try {
        final payload = jsonDecode(raw);
        if (payload is! Map<String, dynamic> ||
            !payload.containsKey('value')) {
          failures.add(
              MigrationKeyIssue(v3Key, 'payload misses "value" projection'));
          continue;
        }
        final actual = digestFor(key, _normalizeJsonValue(payload['value']));
        if (expected == null || actual != expected) {
          failures.add(MigrationKeyIssue(
            v3Key,
            'digest mismatch (count ${actual?.itemCount} vs '
                '${expected?.itemCount}, checksum ${actual?.checksum} vs '
                '${expected?.checksum})',
          ));
        }
      } catch (error) {
        failures.add(MigrationKeyIssue(v3Key, 'unreadable payload: $error'));
      }
    }

    // (b) rollback anchors: the old keys must be untouched.
    for (final entry in backup.entries.entries) {
      final expected = backup.digests[entry.key];
      final actual = digestFor(entry.key, _prefs.get(entry.key));
      if (expected == null || actual == null || actual != expected) {
        failures.add(MigrationKeyIssue(
          entry.key,
          'source key changed during migration '
              '(count ${actual?.itemCount} vs ${expected?.itemCount})',
        ));
      }
    }
    return failures;
  }

  /// Rollback stage: removes every `shelly.v3.*` output key (this run's
  /// and any stale leftovers from a crashed run), then rewrites each
  /// backup entry to its original key verbatim and marks
  /// `shelly.migration.state=rolledback`. Returns whether the rollback
  /// itself completed; its own failures are logged, never thrown.
  Future<bool> _rollback(
    MigrationBackup backup,
    List<MigrationPhaseReport> phases,
  ) async {
    try {
      final v3Keys = _prefs
          .getKeys()
          .where((key) => key.startsWith(kMigratedKeyPrefix))
          .toList();
      for (final key in v3Keys) {
        await _prefs.remove(key);
      }
      for (final entry in backup.entries.entries) {
        await _prefs.set(entry.key, entry.value);
      }
      await _prefs.setString(kMigrationStateKey, stateRolledBack);
      phases.add(MigrationPhaseReport(
        MigrationStage.rollback,
        MigrationPhaseStatus.ok,
        'removed ${v3Keys.length} v3 key(s), '
            'restored ${backup.entries.length} source key(s)',
      ));
      _logger('migration: rolled back '
          '(${v3Keys.length} removed, ${backup.entries.length} restored)');
      return true;
    } catch (error) {
      phases.add(MigrationPhaseReport(
        MigrationStage.rollback,
        MigrationPhaseStatus.failed,
        '$error',
      ));
      _logger('migration: rollback failed: $error');
      return false;
    }
  }

  String _v3KeyFor(String sourceKey) => migrationOutputKeyFor(sourceKey);
}

/// Maps a source key to its migration output key
/// (`shelly.conversations` → `shelly.v3.conversations`).
String migrationOutputKeyFor(String sourceKey) =>
    sourceKey.startsWith('shelly.')
        ? kMigratedKeyPrefix + sourceKey.substring('shelly.'.length)
        : sourceKey;

/// Digest criterion for verify: a (count, checksum) pair over a raw
/// persisted value. Counts: JSON arrays → entry count, checkpoints →
/// `messages.length`, single records and scalars → 1. The checksum is a
/// 32-bit FNV-1a over the canonical JSON encoding (recursively sorted
/// keys), so whitespace and member order never produce false mismatches.
MigrationDigest? digestFor(String key, Object? rawValue) {
  if (rawValue == null) return null;
  var itemCount = 1;
  Object? decoded;
  if (rawValue is String) {
    try {
      decoded = jsonDecode(rawValue);
    } on FormatException {
      decoded = null; // plain string — digest the raw text.
    }
  } else if (rawValue is List) {
    itemCount = rawValue.length;
  }
  if (decoded is List) {
    itemCount = decoded.length;
  } else if (decoded is Map) {
    final messages = decoded['messages'];
    itemCount = messages is List ? messages.length : 1;
  }
  return MigrationDigest(
    itemCount: itemCount,
    checksum: _fnv1a(_canonical(rawValue)),
  );
}

/// jsonDecode round-trips produce `List<dynamic>` even for string lists;
/// restore the `List<String>` runtime type so typed prefs writes work.
Object? _normalizeJsonValue(Object? value) {
  if (value is List && value.every((e) => e is String)) {
    return List<String>.from(value);
  }
  return value;
}

/// Canonical JSON encoding with recursively sorted map keys.
String _canonical(Object? value) {
  if (value is String) {
    Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      decoded = null;
    }
    if (decoded == null) {
      return jsonEncode(value);
    }
    return _canonicalDecoded(decoded);
  }
  return _canonicalDecoded(value);
}

String _canonicalDecoded(Object? value) {
  if (value == null) return 'null';
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return '{'
        '${keys.map((k) => '${jsonEncode(k)}:${_canonicalDecoded(value[k])}').join(',')}'
        '}';
  }
  if (value is List) {
    return '[${value.map(_canonicalDecoded).join(',')}]';
  }
  if (value is bool || value is num) return value.toString();
  if (value is String) return jsonEncode(value);
  return jsonEncode(value.toString());
}

/// 32-bit FNV-1a hash (portable across the VM and the web harness).
int _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
