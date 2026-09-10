import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/core/migration/migration_keys.dart';
import 'package:shelly_hermes/core/migration/migration_manager.dart';
import 'package:shelly_hermes/core/migration/migration_prefs.dart';

/// In-memory [MigrationPrefs] fake — the whole pipeline must run against
/// this exactly as it runs against SharedPreferences in production.
class _FakePrefs implements MigrationPrefs {
  _FakePrefs([Map<String, Object>? initial]) : _data = {...?initial};

  final Map<String, Object> _data;

  @override
  Set<String> getKeys() => _data.keys.toSet();

  @override
  Object? get(String key) => _data[key];

  @override
  String? getString(String key) {
    final value = _data[key];
    return value is String ? value : null;
  }

  @override
  Future<void> set(String key, Object? value) async {
    if (value == null) {
      _data.remove(key);
      return;
    }
    _data[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _data.remove(key);
  }
}

/// Fake that simulates the host rejecting migration output writes while
/// every other operation keeps working (migrate-failure path).
class _V3WriteFailingPrefs extends _FakePrefs {
  _V3WriteFailingPrefs([super.initial]);

  @override
  Future<void> setString(String key, String value) async {
    if (key.startsWith(kMigratedKeyPrefix)) {
      throw StateError('prefs write rejected for $key');
    }
    await super.setString(key, value);
  }
}

const _conversationsJson =
    '[{"id":"c1","title":"First","updatedAt":"2026-09-01T10:00:00.000Z",'
    '"messageCount":4,"pinned":false},'
    '{"id":"c2","title":"Second","updatedAt":"2026-09-02T10:00:00.000Z",'
    '"messageCount":2,"pinned":true}]';

const _factsJson =
    '[{"id":"f1","text":"likes tea","createdAt":"2026-08-01T00:00:00.000Z",'
    '"tier":"recall"},'
    '{"id":"f2","text":"has a dog","createdAt":"2026-08-02T00:00:00.000Z",'
    '"tier":"core"}]';

const _checkpointJson =
    '{"version":1,"messages":[{"role":"user","content":"hi"}],'
    '"round":2,"consumedTokens":100,"toolCalls":1,"pendingToolCalls":[]}';

const _modelConfigJson =
    '{"baseUrl":"https://api.example.com","apiKey":"","model":"gpt-test"}';

/// A representative v2.x seed: JSON payloads, typed scalars, a string
/// list, a plain string, plus one non-shelly key that must be ignored.
Map<String, Object> _seedPrefs() => {
      'shelly.conversations': _conversationsJson,
      'shelly.memory.facts': _factsJson,
      'shelly.checkpoint.c1': _checkpointJson,
      'shelly.model.config': _modelConfigJson,
      'shelly.tts.enabled': true,
      'shelly.update.lastcheck': 1755100000000,
      'shelly.lan.token': 'pair-token-42',
      'shelly.plugin.installed': ['dsh-sqlite'],
      'flutter.counter': 7,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DateTime fixedClock() => DateTime.utc(2026, 9, 10, 8);

  test('normal migration: new keys written, old keys kept, backup stored',
      () async {
    final prefs = _FakePrefs(_seedPrefs());
    final manager = MigrationManager(prefs: prefs, clock: fixedClock);
    final keysBefore = prefs.getKeys().toSet();

    final result = await manager.run();

    expect(result.skipped, isFalse, reason: 'fresh store must run');
    expect(result.success, isTrue, reason: 'error: ${result.errorMessage}');
    expect(result.rolledBack, isFalse);
    expect(result.invalidKeys, isEmpty);
    expect(result.unknownKeys, isEmpty);
    expect(result.errorMessage, isNull);

    // backup: single JSON key, schemaVersion + timestamp + verbatim values.
    final backupRaw = prefs.getString(kMigrationBackupKey);
    expect(backupRaw, isNotNull);
    final backup = jsonDecode(backupRaw!) as Map<String, dynamic>;
    expect(backup['schemaVersion'], 3);
    expect(backup['backupAt'], '2026-09-10T08:00:00.000Z');
    final entries = backup['entries'] as Map<String, dynamic>;
    expect(
      entries.keys.toSet(),
      {
        'shelly.conversations',
        'shelly.memory.facts',
        'shelly.checkpoint.c1',
        'shelly.model.config',
        'shelly.tts.enabled',
        'shelly.update.lastcheck',
        'shelly.lan.token',
        'shelly.plugin.installed',
      },
      reason: 'all shelly.* data keys, no migration keys, no foreign keys',
    );
    expect(entries['shelly.conversations'], _conversationsJson);
    expect(entries['shelly.tts.enabled'], isTrue);
    expect(entries['shelly.plugin.installed'], ['dsh-sqlite']);
    final digests = backup['digests'] as Map<String, dynamic>;
    expect((digests['shelly.conversations'] as Map)['count'], 2);
    expect((digests['shelly.memory.facts'] as Map)['count'], 2);
    // Checkpoint count = messages.length (V3_MIGRATION_PLAN §1 verify).
    expect((digests['shelly.checkpoint.c1'] as Map)['count'], 1);

    // migrate: envelope payload under shelly.v3.*, original verbatim under
    // 'value'.
    final conversationsPayload =
        jsonDecode(prefs.getString('shelly.v3.conversations')!)
            as Map<String, dynamic>;
    expect(conversationsPayload['schemaVersion'], 3);
    expect(conversationsPayload['source'], 'shelly.conversations');
    expect(conversationsPayload['value'], _conversationsJson);
    final ttsPayload =
        jsonDecode(prefs.getString('shelly.v3.tts.enabled')!) as Map;
    expect(ttsPayload['value'], isTrue);
    expect(prefs.getString('shelly.v3.checkpoint.c1'), isNotNull);
    expect(prefs.getString('shelly.v3.plugin.installed'), isNotNull);

    // old keys survive untouched (rollback anchor).
    for (final key in keysBefore) {
      expect(prefs.get(key), _seedPrefs()[key], reason: '$key changed');
    }

    // verify + terminal state.
    expect(prefs.getString(kMigrationStateKey), 'completed');
    expect(
      result.phases.lastWhere((p) => p.stage == MigrationStage.verify).status,
      MigrationPhaseStatus.ok,
    );
  });

  test('empty prefs: run completes normally with no data side effects',
      () async {
    final prefs = _FakePrefs();
    final result = await MigrationManager(prefs: prefs, clock: fixedClock)
        .run();

    expect(result.success, isTrue, reason: 'error: ${result.errorMessage}');
    expect(result.backedUpKeys, isEmpty);
    expect(result.migratedKeys, isEmpty);
    expect(result.invalidKeys, isEmpty);
    expect(result.verifyFailures, isEmpty);

    // Only the two migration bookkeeping keys exist afterwards — no
    // shelly.v3.* output, no data keys.
    final backup = jsonDecode(prefs.getString(kMigrationBackupKey)!)
        as Map<String, dynamic>;
    expect((backup['entries'] as Map).isEmpty, isTrue);
    expect(prefs.getString(kMigrationStateKey), 'completed');
    expect(
      prefs.getKeys().where((k) => k.startsWith(kMigratedKeyPrefix)),
      isEmpty,
    );
  });

  test('corrupt key: validate records and continues, never migrates it',
      () async {
    final seed = _seedPrefs();
    seed['shelly.memory.facts'] = '{"broken';
    seed['shelly.exotic.new'] = 'plain-value';
    final prefs = _FakePrefs(seed);
    final log = <String>[];
    final result = await MigrationManager(
      prefs: prefs,
      clock: fixedClock,
      logger: log.add,
    ).run();

    // Bad key is reported, not fatal.
    expect(result.success, isTrue, reason: 'error: ${result.errorMessage}');
    expect(result.invalidKeys, hasLength(1));
    expect(result.invalidKeys.single.key, 'shelly.memory.facts');
    expect(result.invalidKeys.single.reason, contains('invalid JSON'));
    expect(
      log.any((line) => line.contains('shelly.memory.facts')),
      isTrue,
      reason: 'bad keys must reach the injectable logger',
    );

    // Unknown shelly.* key: backed up and migrated, only flagged unknown.
    expect(result.unknownKeys, ['shelly.exotic.new']);
    expect(result.backedUpKeys, contains('shelly.exotic.new'));
    expect(result.migratedKeys, contains('shelly.exotic.new'));

    // Corrupt payload gets no v3 twin; everything else migrates.
    expect(result.migratedKeys, isNot(contains('shelly.memory.facts')));
    expect(prefs.getString('shelly.v3.memory.facts'), isNull);
    expect(prefs.getString('shelly.v3.conversations'), isNotNull);
    // The corrupt raw value still survives verbatim in prefs and backup.
    expect(prefs.getString('shelly.memory.facts'), '{"broken');
    final backup = jsonDecode(prefs.getString(kMigrationBackupKey)!)
        as Map<String, dynamic>;
    expect((backup['entries'] as Map)['shelly.memory.facts'], '{"broken');
    expect(prefs.getString(kMigrationStateKey), 'completed');
  });

  test('verify failure on a migrated key triggers automatic rollback',
      () async {
    final prefs = _FakePrefs(_seedPrefs());
    final manager = MigrationManager(
      prefs: prefs,
      clock: fixedClock,
      afterMigrateHook: () async {
        // Tamper the migrated payload: one fact instead of two.
        final payload =
            jsonDecode(prefs.getString('shelly.v3.memory.facts')!)
                as Map<String, dynamic>;
        payload['value'] =
            '[{"id":"f1","text":"likes tea","createdAt":"2026-08-01T00:00:00.000Z","tier":"recall"}]';
        await prefs.setString(
            'shelly.v3.memory.facts', jsonEncode(payload));
      },
    );

    final result = await manager.run();

    expect(result.success, isFalse);
    expect(result.rolledBack, isTrue);
    expect(result.verifyFailures, hasLength(1));
    expect(result.verifyFailures.single.key, 'shelly.v3.memory.facts');
    expect(
      result.verifyFailures.single.reason,
      contains('digest mismatch'),
    );
    expect(
      result.phases.lastWhere((p) => p.stage == MigrationStage.rollback)
          .status,
      MigrationPhaseStatus.ok,
    );

    // Rollback semantics: every shelly.v3.* output key removed, old keys
    // restored verbatim from the backup, state marked.
    expect(
      prefs.getKeys().where((k) => k.startsWith(kMigratedKeyPrefix)),
      isEmpty,
      reason: 'rollback must remove all migration output keys',
    );
    expect(prefs.getString('shelly.memory.facts'), _factsJson);
    expect(prefs.getString('shelly.conversations'), _conversationsJson);
    expect(prefs.get('shelly.tts.enabled'), isTrue);
    expect(prefs.get('shelly.update.lastcheck'), 1755100000000);
    expect(prefs.get('shelly.plugin.installed'), ['dsh-sqlite']);
    expect(prefs.getString(kMigrationStateKey), 'rolledback');
    // The backup itself survives the rollback (audit anchor).
    expect(prefs.getString(kMigrationBackupKey), isNotNull);
  });

  test('verify failure on an old key (anchor clobbered) also rolls back',
      () async {
    final prefs = _FakePrefs(_seedPrefs());
    final result = await MigrationManager(
      prefs: prefs,
      clock: fixedClock,
      afterMigrateHook: () async {
        // Something overwrites a source key between migrate and verify.
        await prefs.setString(
          'shelly.conversations',
          '[{"id":"c9","title":"Rogue","updatedAt":"2026-09-03T00:00:00.000Z",'
          '"messageCount":1,"pinned":false}]',
        );
      },
    ).run();

    expect(result.success, isFalse);
    expect(result.rolledBack, isTrue);
    expect(
      result.verifyFailures.any((issue) =>
          issue.key == 'shelly.conversations' &&
          issue.reason.contains('source key changed')),
      isTrue,
    );
    // Rollback restores the ORIGINAL value from the backup.
    expect(prefs.getString('shelly.conversations'), _conversationsJson);
    expect(
      prefs.getKeys().where((k) => k.startsWith(kMigratedKeyPrefix)),
      isEmpty,
    );
    expect(prefs.getString(kMigrationStateKey), 'rolledback');
  });

  test('migrate write failure triggers rollback and never throws',
      () async {
    final prefs = _V3WriteFailingPrefs(_seedPrefs());
    final result = await MigrationManager(prefs: prefs, clock: fixedClock)
        .run();

    expect(result.success, isFalse);
    expect(result.rolledBack, isTrue);
    expect(result.errorMessage, contains('migrate failed'));
    expect(result.migratedKeys, isEmpty);
    expect(
      prefs.getKeys().where((k) => k.startsWith(kMigratedKeyPrefix)),
      isEmpty,
    );
    expect(prefs.getString('shelly.conversations'), _conversationsJson);
    expect(prefs.getString(kMigrationStateKey), 'rolledback');
  });

  test('re-running after completion is a no-op (backup never overwritten)',
      () async {
    final prefs = _FakePrefs(_seedPrefs());
    final manager = MigrationManager(prefs: prefs, clock: fixedClock);
    await manager.run();

    final backupAfterFirstRun = prefs.getString(kMigrationBackupKey);
    final v3Conversations = prefs.getString('shelly.v3.conversations');

    final second = await manager.run();

    expect(second.skipped, isTrue);
    expect(second.success, isTrue);
    expect(second.rolledBack, isFalse);
    expect(
      second.phases.every((p) => p.status == MigrationPhaseStatus.skipped),
      isTrue,
    );
    expect(prefs.getString(kMigrationBackupKey), backupAfterFirstRun);
    expect(prefs.getString('shelly.v3.conversations'), v3Conversations);
    expect(prefs.getString(kMigrationStateKey), 'completed');
    // Old keys untouched by the second run.
    expect(prefs.getString('shelly.conversations'), _conversationsJson);
  });

  test('crash mid-migration: next run reuses the existing backup',
      () async {
    final prefs = _FakePrefs(_seedPrefs());
    final manager = MigrationManager(prefs: prefs, clock: fixedClock);
    await manager.run();

    // Simulate a crash after backup+migrate but before the state write.
    await prefs.remove(kMigrationStateKey);
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(kMigratedKeyPrefix)) await prefs.remove(key);
    }
    final backupFromCrashedRun = prefs.getString(kMigrationBackupKey);

    final second = await manager.run();

    expect(second.skipped, isFalse);
    expect(second.reusedBackup, isTrue);
    expect(second.success, isTrue, reason: 'error: ${second.errorMessage}');
    expect(
      second.phases
          .lastWhere((p) => p.stage == MigrationStage.backup)
          .detail,
      contains('reused existing backup'),
    );
    // The anchor was not overwritten by the recovery run.
    expect(prefs.getString(kMigrationBackupKey), backupFromCrashedRun);
    // v3 twins rewritten from the same snapshot.
    expect(prefs.getString('shelly.v3.conversations'), isNotNull);
    expect(prefs.getString(kMigrationStateKey), 'completed');
  });

  test('digest is order- and whitespace-insensitive with item counts',
      () {
    final a = digestFor('k', '{"a":1,"b":[2,3]}')!;
    final b = digestFor('k', '{ "b" : [2,3], "a" : 1 }')!;
    expect(a.checksum, b.checksum);
    expect(a.itemCount, 1);

    expect(digestFor('k', '[{"id":1},{"id":2},{"id":3}]')!.itemCount, 3);
    // Plain scalars digest their raw representation.
    expect(digestFor('k', true)!.itemCount, 1);
    expect(digestFor('k', null), isNull);
  });
}
