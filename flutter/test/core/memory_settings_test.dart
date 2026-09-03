import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/hermes/knowledge.dart';
import 'package:shelly_hermes/core/hermes/knowledge_store.dart';
import 'package:shelly_hermes/core/hermes/memory_settings.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/state/hermes_provider.dart';

void main() {
  test('MemorySettings round-trips through JSON', () {
    const settings = MemorySettings(
      maxLedgerTokens: 20000,
      activeDays: 21,
      coolingDays: 120,
      frequencyFloor: 5,
      maxAutoEntries: 500,
      recallEntries: 12,
      recallTokens: 2000,
    );

    final restored =
        MemorySettings.fromJson(settings.toJson());

    expect(restored.maxLedgerTokens, 20000);
    expect(restored.activeDays, 21);
    expect(restored.coolingDays, 120);
    expect(restored.frequencyFloor, 5);
    expect(restored.maxAutoEntries, 500);
    expect(restored.recallEntries, 12);
    expect(restored.recallTokens, 2000);
  });

  test('MemorySettings.fromTolerates missing and out-of-range values',
      () {
    final restored = MemorySettings.fromJson({});

    // Missing values fall back to the raised defaults.
    expect(restored.maxLedgerTokens, 16000);
    expect(restored.maxAutoEntries, 300);

    final clamped = MemorySettings.fromJson(const {
      'maxLedgerTokens': 999999999,
      'activeDays': -5,
      'recallEntries': 0,
      'recallTokens': 1,
    });

    expect(clamped.maxLedgerTokens, 200000);
    expect(clamped.activeDays, 1);
    expect(clamped.recallEntries, 1);
    expect(clamped.recallTokens, 100);
  });

  test('runUpkeepWith merges duplicates and drops expired entries',
      () async {
    final workspace = MemoryWorkspace();
    final store = HermesKnowledgeStore(workspace: workspace, project: 'demo');

    final now = DateTime.now();
    await store.append(KnowledgeEntry(
      id: 'k-1',
      content: '部署前必须运行 flutter analyze 保持零告警',
      lastTriggeredAt: now,
    ));
    await store.append(KnowledgeEntry(
      id: 'k-2',
      content: '部署前必须运行 flutter analyze 保持零告警',
      lastTriggeredAt: now,
    ));
    await store.append(KnowledgeEntry(
      id: 'k-old',
      content: '很久没用的过期知识条目,早已无人召回',
      lastTriggeredAt: now.subtract(const Duration(days: 400)),
    ));

    final report = await runUpkeepWith(
      workspace: workspace,
      project: 'demo',
      settings: const MemorySettings(),
    );

    expect(report.absorbedEntries, 1, reason: 'exact duplicate folded');
    expect(report.droppedEntries, 1, reason: 'stale entry expired');
    expect(report.remainingEntries, 1,
        reason: 'the duplicate is absorbed, the stale entry is dropped');

    final remaining = await store.loadAll();
    expect(remaining.map((e) => e.id), ['k-1']);
  });
}
