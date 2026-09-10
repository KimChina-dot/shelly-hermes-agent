// PHASE 15 safety net (TEST_COVERAGE_MAP §3): direct tests for
// hermes_provider.dart — the audit found no direct tests (hermesLedgerProvider
// was only touched indirectly via memory_tier_ui_test), so provider-graph
// changes had no gate.
//
// The real prefs chain is exercised end-to-end: SharedPreferences is mocked
// with a `shelly.memory.settings` payload, the REAL settingsStoreProvider
// (SharedPreferences.getInstance + createSecureBox + restoreApiKey) runs
// against it, and hermesLedgerProvider must derive its forgetting policy
// from those stored values — not from the defaults. The workspace side is
// a MemoryWorkspace seeded with a knowledge ledger.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/core/hermes/forgetting.dart'
    show KnowledgeVitality;
import 'package:shelly_hermes/core/hermes/knowledge.dart';
import 'package:shelly_hermes/core/hermes/memory_settings.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/state/chat_session.dart' show workspaceProvider;
import 'package:shelly_hermes/state/hermes_provider.dart';
import 'package:shelly_hermes/state/settings_store.dart';

KnowledgeEntry _entry(
  String id,
  String content, {
  int daysAgoTriggered = 0,
  int frequency = 0,
}) =>
    KnowledgeEntry(
      id: id,
      content: content,
      lastTriggeredAt: DateTime.now().subtract(Duration(days: daysAgoTriggered)),
      createdAt: DateTime.now().subtract(const Duration(days: 200)),
      frequency: frequency,
    );

String _ledger(List<KnowledgeEntry> entries) => entries
    .map((e) => jsonEncode(e.toJson()))
    .join('\n');

///Prefs payload with NON-default values, so assertions prove the settings
/// came from prefs rather than `const MemorySettings()`.
const _prefsSettings = {
  'shelly.memory.settings':
      '{"maxLedgerTokens":500,"activeDays":1,"coolingDays":30,"frequencyFloor":3}',
};

void main() {
  test('hermesLedgerProvider derives vitality from prefs-driven settings',
      () async {
    SharedPreferences.setMockInitialValues(_prefsSettings);

    final workspace = MemoryWorkspace({
      '.shelly/knowledge.jsonl': _ledger([
        _entry('k-active', '刚用过的经验'),
        _entry('k-cooling', '几天没用的经验', daysAgoTriggered: 5),
        _entry('k-expired', '很久没用的旧经验', daysAgoTriggered: 100),
        // High recall frequency shields an entry from pure age expiry.
        _entry('k-hot', '高频使用的核心经验',
            daysAgoTriggered: 100, frequency: 5),
      ]),
    });

    final container = ProviderContainer(overrides: [
      workspaceProvider.overrideWithValue(workspace),
    ]);
    addTearDown(container.dispose);

    // Prime the real settings provider (prefs + secure box) first, the
    // same way the app does on startup.
    await container.read(settingsStoreProvider.future);

    final snapshot = await container.read(hermesLedgerProvider.future);

    // Settings came through the REAL prefs chain, not the defaults.
    expect(snapshot.settings.maxLedgerTokens, 500);
    expect(snapshot.settings.activeDays, 1);
    expect(snapshot.settings.coolingDays, 30);
    expect(snapshot.settings.frequencyFloor, 3);

    // Ledger contents loaded from the workspace.
    expect(snapshot.entries.map((e) => e.id),
        containsAll(['k-active', 'k-cooling', 'k-expired', 'k-hot']));

    // Vitality under the prefs-driven policy (activeDays=1, coolingDays=30,
    // frequencyFloor=3; timestamps are far from every boundary).
    expect(snapshot.vitalityOf(_byId(snapshot, 'k-active')),
        KnowledgeVitality.active);
    expect(snapshot.vitalityOf(_byId(snapshot, 'k-cooling')),
        KnowledgeVitality.cooling);
    expect(snapshot.vitalityOf(_byId(snapshot, 'k-expired')),
        KnowledgeVitality.expired);
    expect(snapshot.vitalityOf(_byId(snapshot, 'k-hot')),
        KnowledgeVitality.active);

    expect(snapshot.countOf(KnowledgeVitality.active), 2);
    expect(snapshot.countOf(KnowledgeVitality.cooling), 1);
    expect(snapshot.countOf(KnowledgeVitality.expired), 1);

    // Token budget = sum of per-entry estimates (same estimator).
    final expectedTokens = snapshot.entries
        .fold<int>(0, (sum, e) => sum + estimateTokens(e.content));
    expect(snapshot.totalTokens, expectedTokens);
    expect(snapshot.totalTokens, greaterThan(0));
  });

  test('hermesLedgerProvider falls back to defaults without stored settings',
      () async {
    SharedPreferences.setMockInitialValues({});
    final workspace = MemoryWorkspace(); // no ledger file at all

    final container = ProviderContainer(overrides: [
      workspaceProvider.overrideWithValue(workspace),
    ]);
    addTearDown(container.dispose);
    await container.read(settingsStoreProvider.future);

    final snapshot = await container.read(hermesLedgerProvider.future);
    expect(snapshot.entries, isEmpty);
    expect(snapshot.vitality, isEmpty);
    expect(snapshot.totalTokens, 0);
    expect(snapshot.settings, const MemorySettings());
  });

  test('runUpkeepWith drops expired entries and rewrites the ledger file',
      () async {
    final workspace = MemoryWorkspace({
      '.shelly/knowledge.jsonl': _ledger([
        _entry('k-keep', '保留:仍然活跃的经验'),
        _entry('k-drop', '过期:该被遗忘的经验', daysAgoTriggered: 100),
      ]),
    });

    final report = await runUpkeepWith(
      workspace: workspace,
      project: 'demo',
      settings: const MemorySettings(
          maxLedgerTokens: 500, activeDays: 1, coolingDays: 30),
    );

    expect(report.droppedEntries, 1);
    expect(report.droppedReasons, containsPair('k-drop', 'expired'));
    expect(report.remainingEntries, 1);

    // The forgetting pass persisted the survivors through the real store.
    final rewritten =
        workspace.files['.shelly/knowledge.jsonl'] ?? '';
    expect(rewritten, contains('k-keep'));
    expect(rewritten, isNot(contains('k-drop')));
  });
}

KnowledgeEntry _byId(HermesLedgerSnapshot snapshot, String id) =>
    snapshot.entries.firstWhere((e) => e.id == id);
