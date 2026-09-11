/// PHASE 18 (plan P8) cutover tests: the boot seam runs the five-stage
/// migration exactly once per install, fail-open on every failure mode,
/// with one evidence line per run.
///
/// The upgrade matrix drives three era-shaped archives (v2.2 → v2.3 →
/// v2.4-style key sets, shapes per the R1 catalog in migration_keys.dart)
/// through the real pipeline and pins the P8 invariants: old keys survive
/// byte-identical (rollback anchor), a completed install re-runs as a
/// no-op, a mid-write failure rolls back automatically, a hung host hits
/// the boot timeout without blocking startup, and every outcome lands in
/// the evidence sink.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/core/migration/migration_bootstrap.dart';
import 'package:shelly_hermes/core/migration/migration_keys.dart';
import 'package:shelly_hermes/core/migration/migration_manager.dart';
import 'package:shelly_hermes/core/migration/migration_prefs.dart';

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

/// Rejects every `shelly.v3.*` write while other operations keep working —
/// the deterministic migrate-failure shape for the rollback drill.
class _V3WriteFailingPrefs extends _FakePrefs {
  _V3WriteFailingPrefs([super.initial]);

  @override
  Future<void> set(String key, Object? value) async {
    if (key.startsWith(kMigratedKeyPrefix) && value != null) {
      throw StateError('host rejected v3 write: $key');
    }
    await super.set(key, value);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key.startsWith(kMigratedKeyPrefix)) {
      throw StateError('host rejected v3 write: $key');
    }
    await super.setString(key, value);
  }
}

/// Every write hangs forever — the pathological host for the boot timeout.
class _HangingPrefs extends _FakePrefs {
  _HangingPrefs([super.initial]);

  @override
  Future<void> set(String key, Object? value) => Completer<void>().future;

  @override
  Future<void> setString(String key, String value) =>
      Completer<void>().future;
}

class _EvidenceLog {
  final entries = <(String, String)>[];

  Future<void> call(String context, Object message) async {
    entries.add((context, message.toString()));
  }

  String get resultLine => entries
      .map((e) => e.$2)
      .lastWhere((line) => line.startsWith('state='));
}

// ---------------------------------------------------------------------------
// Era-shaped archives. Key membership models each era's catalog (earlier
// installs predate the later keys); json-kind values are stored as real
// hosts store them — JSON strings via setString — plain kinds stay typed.
// ---------------------------------------------------------------------------

/// The prefs keys whose values are JSON payloads (jsonList/jsonMap kinds in
/// the R1 catalog) — encoded to strings the way every store writes them.
const _jsonKeys = <String>{
  'shelly.model.config',
  'shelly.model.aux',
  'shelly.task.active',
  'shelly.memory.settings',
  'shelly.mcp.toolprints',
  'shelly.mcp.bridge',
  'shelly.sched.bgstate',
  'shelly.capability.trust',
};

const _jsonListKeys = <String>{
  'shelly.conversations',
  'shelly.agent.profiles',
  'shelly.mcp.servers',
  'shelly.mcp.stdio',
  'shelly.memory.facts',
  'shelly.crash.logs',
  'shelly.usage.stats',
  'shelly.sched.tasks',
  'shelly.mission.missions',
};

Map<String, Object> _asStored(Map<String, Object> raw) => {
      for (final entry in raw.entries)
        entry.key: _jsonKeys.contains(entry.key) ||
                _jsonListKeys.contains(entry.key) ||
                entry.key.startsWith('shelly.checkpoint.')
            ? jsonEncode(entry.value)
            : entry.value,
    };

Map<String, Object> _conversationEntry(String id) => {
      'id': id,
      'title': '对话 $id',
      'updatedAt': 1725900000000 + id.hashCode.abs() % 1000,
      'messageCount': 4,
    };

Map<String, Object> _checkpoint(String convId) => {
      'version': 1,
      'messages': [
        {
          'role': 'user',
          'content': '整理桌面文件',
          'toolCallId': null,
          'toolCalls': [],
        },
      ],
      'round': 2,
      'consumedTokens': 1280,
      'toolCalls': 3,
      'pendingToolCalls': [],
    };

/// v2.2-era install: the early core keys.
Map<String, Object> _v22Archive() => _asStored({
      'shelly.model.config': {
        'baseUrl': 'https://api.example.com/v1',
        'apiKey': 'sk-old',
        'model': 'deepseek-chat',
      },
      'shelly.conversations': [_conversationEntry('c-1'), _conversationEntry('c-2')],
      'shelly.agent.profiles': [
        {'id': 'default', 'name': '默认', 'maxRounds': 16, 'maxToolCalls': 32},
      ],
      'shelly.agent.profile.active': 'default',
      'shelly.task.active': {
        'conversationId': 'c-1',
        'taskId': 'task-1725900000',
        'startedAt': '2026-09-01T10:00:00Z',
      },
      'shelly.memory.settings': {'recallEntries': 5, 'recallTokens': 800},
      'shelly.memory.facts': [
        {'id': 'f-1', 'text': '用户偏好简洁回复', 'createdAt': '2026-08-01T00:00:00Z'},
      ],
      'shelly.crash.logs': [
        {'context': 'boot', 'error': 'x', 'stack': '', 'at': '2026-08-02T00:00:00Z'},
      ],
      'shelly.checkpoint.c-1': _checkpoint('c-1'),
    });

/// v2.3-era install: v2.2 plus the mid-cycle keys (MCP, scheduling, usage,
/// LAN, plugins, update).
Map<String, Object> _v23Archive() => _asStored({
      ..._v22Archive(),
      'shelly.mcp.servers': [
        {'id': 'github', 'url': 'https://mcp.example.com/sse', 'enabled': true},
      ],
      'shelly.mcp.toolprints': {'github': 'fp-001'},
      'shelly.tts.enabled': false,
      'shelly.usage.stats': [
        {'model': 'deepseek-chat', 'inputTokens': 900, 'outputTokens': 100},
      ],
      'shelly.sched.tasks': [
        {'id': 's-1', 'prompt': '每日总结', 'hour': 9, 'enabled': true},
      ],
      'shelly.memory.maintenance.lastRun': 1725800000000,
      'shelly.lan.enabled': true,
      'shelly.lan.token': 'pair-token-1',
      'shelly.plugin.installed': ['com.example.toolkit'],
      'shelly.update.lastcheck': 1725850000000,
    });

/// v2.4-era install: the full live catalog incl. the post-R1 keys.
Map<String, Object> _v24Archive() => _asStored({
      ..._v23Archive(),
      'shelly.model.aux': {
        'baseUrl': 'https://api.example.com/v1',
        'apiKey': '',
        'model': 'glm-4-flash',
      },
      'shelly.model.aux.enabled': true,
      'shelly.mcp.stdio': [
        {'name': 'local-tools', 'command': 'node', 'args': ['mcp.js']},
      ],
      'shelly.mcp.bridge': {'baseUrl': 'http://192.168.1.10:8770', 'token': 't'},
      'shelly.sched.bgstate': {'dueCount': 2},
      'shelly.capability.trust': {'terminal': 0.8},
      'shelly.mission.missions': [
        {'id': 'm-1', 'title': '整理桌面文件', 'status': 'completed'},
      ],
      'shelly.memory.recallAgeDays': 30,
      'shelly.memory.archivalCap': 200,
      'shelly.checkpoint.c-2': _checkpoint('c-2'),
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _EvidenceLog evidence;

  setUp(() {
    evidence = _EvidenceLog();
  });

  group('upgrade matrix: era archives migrate with old keys intact', () {
    for (final era in [('v2.2', _v22Archive), ('v2.3', _v23Archive), ('v2.4', _v24Archive)]) {
      test('${era.$1} archive upgrades through the boot seam', () async {
        final fixture = era.$2();
        final prefs = _FakePrefs(fixture);

        await runStartupMigration(prefs: prefs, evidence: evidence.call);

        // Completed, evidenced.
        expect(prefs.getString(kMigrationStateKey),
            MigrationManager.stateCompleted);
        expect(evidence.resultLine, startsWith('state=completed'));
        // The rollback anchor: every old key byte-identical.
        for (final entry in fixture.entries) {
          expect(prefs.get(entry.key), entry.value,
              reason: '${era.$1} key ${entry.key} must survive verbatim');
        }
        // Backup snapshot exists.
        expect(prefs.getString(kMigrationBackupKey), isNotNull);
      });
    }

    test('a completed install re-runs as an evidenced no-op', () async {
      final fixture = _v24Archive();
      final prefs = _FakePrefs(fixture);
      await runStartupMigration(prefs: prefs, evidence: evidence.call);
      final backupAfterFirst = prefs.getString(kMigrationBackupKey);

      await runStartupMigration(prefs: prefs, evidence: evidence.call);

      expect(evidence.resultLine, startsWith('state=skipped'));
      // The idempotency anchor: the backup is never overwritten.
      expect(prefs.getString(kMigrationBackupKey), backupAfterFirst);
      for (final entry in fixture.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
    });
  });

  group('failure drills (P8 gate: rollback rehearsal + evidence)', () {
    test('migrate write failure rolls back and startup continues', () async {
      final fixture = _v23Archive();
      final prefs = _V3WriteFailingPrefs(fixture);

      await runStartupMigration(prefs: prefs, evidence: evidence.call);

      // Rolled back, evidenced, and the boot seam returned normally (the
      // test reaching the expects IS the fail-open proof).
      expect(prefs.getString(kMigrationStateKey),
          MigrationManager.stateRolledBack);
      expect(evidence.resultLine, contains('rolledBack=true'));
      // Anchor untouched: the store equals the pre-migration state.
      for (final entry in fixture.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
      // No v3 output keys survive the rollback.
      expect(
        prefs.getKeys().where((k) => k.startsWith(kMigratedKeyPrefix)),
        isEmpty,
      );
    });

    test('a run killed mid-way re-anchors on the surviving backup', () async {
      final fixture = _v22Archive();
      final prefs = _FakePrefs(fixture);
      await runStartupMigration(prefs: prefs, evidence: evidence.call);
      // Simulate a crash after migrate but before the state write: drop the
      // terminal marker and one v3 twin; the backup survives.
      await prefs.remove(kMigrationStateKey);
      await prefs.remove(migrationOutputKeyFor('shelly.conversations'));

      await runStartupMigration(prefs: prefs, evidence: evidence.call);

      expect(prefs.getString(kMigrationStateKey),
          MigrationManager.stateCompleted);
      expect(evidence.resultLine, contains('reusedBackup=true'));
      expect(
        prefs.getString(migrationOutputKeyFor('shelly.conversations')),
        isNotNull,
      );
    });

    test('a hung host hits the boot timeout without blocking', () async {
      final prefs = _HangingPrefs(_v22Archive());
      final watch = Stopwatch()..start();

      await runStartupMigration(
        prefs: prefs,
        evidence: evidence.call,
        timeout: const Duration(milliseconds: 200),
      );

      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        evidence.entries.map((e) => e.$1),
        contains('migration.timeout'),
      );
    });

    test('a fresh install (empty prefs) is a completed no-op', () async {
      final prefs = _FakePrefs();

      await runStartupMigration(prefs: prefs, evidence: evidence.call);

      expect(prefs.getString(kMigrationStateKey),
          MigrationManager.stateCompleted);
      expect(evidence.resultLine, contains('backedUp=0'));
    });
  });
}
