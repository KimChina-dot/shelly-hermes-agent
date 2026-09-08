import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/state/memory_maintenance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed anchor for the injectable clock, so throttle and aging are
  // deterministic.
  final base = DateTime(2026, 9, 1, 12);
  DateTime daysAgo(int days) => base.subtract(Duration(days: days));

  // Seed facts straight into the store's JSON (the consolidator reads back
  // through MemoryFact.fromJson; tier names ride in the same entries).
  Map<String, dynamic> factJson(
    String id,
    String text,
    DateTime createdAt, {
    String? tier,
  }) =>
      {
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'tier': ?tier,
      };

  Future<SharedPreferences> mockPrefs([Map<String, Object>? values]) async {
    SharedPreferences.setMockInitialValues(values ?? const {});
    return SharedPreferences.getInstance();
  }

  test('daily throttle: first run passes, immediate rerun is skipped, '
      'force bypasses', () async {
    final prefs = await mockPrefs();
    final store = MemoryStore(prefs);
    await store.addFacts(['用户偏好简洁回复'], at: daysAgo(1));

    var now = base;
    final service = MemoryMaintenanceService(clock: () => now);

    // First automatic pass: no last-run stamp, so it runs.
    final first = await service.runIfNeeded(store);
    expect(first, isNotNull);
    expect(prefs.getInt(MemoryMaintenanceService.lastRunKey),
        base.millisecondsSinceEpoch);

    // Immediate rerun: inside the 20h window, skipped (null).
    expect(await service.runIfNeeded(store), isNull);

    // force bypasses the throttle without moving the clock.
    final forced = await service.runIfNeeded(store, force: true);
    expect(forced, isNotNull);
    expect(prefs.getInt(MemoryMaintenanceService.lastRunKey),
        base.millisecondsSinceEpoch);

    // Still throttled 19h after the last stamp…
    now = base.add(const Duration(hours: 19));
    expect(await service.runIfNeeded(store), isNull);

    // …and runs again once the window has elapsed.
    now = base.add(const Duration(hours: 20, minutes: 1));
    final afterWindow = await service.runIfNeeded(store);
    expect(afterWindow, isNotNull);
  });

  test('stamps the last-run timestamp BEFORE the pass runs', () async {
    // An old recall fact plus 0-day aging: the pass has real work to do,
    // so it consumes a clock read of its own.
    final prefs = await mockPrefs({
      MemoryMaintenanceService.recallAgeDaysKey: 0,
      MemoryStore.storageKey: jsonEncode([
        factJson('f1', '用户偏好简洁回复', daysAgo(10), tier: 'recall'),
      ]),
    });
    final store = MemoryStore(prefs);

    // Every clock read advances one minute and is recorded: the service
    // reads once (throttle check + stamp), the consolidator once (aging).
    final reads = <DateTime>[];
    final service = MemoryMaintenanceService(clock: () {
      final read = base.add(Duration(minutes: reads.length + 1));
      reads.add(read);
      return read;
    });

    final report = await service.runIfNeeded(store);
    expect(report, isNotNull);
    expect(report!.demoted, 1); // the pass really ran and aged the fact
    expect(reads, hasLength(2));

    // The stamp carries the FIRST clock read. A post-run stamp would carry
    // the second (the consolidator's) read instead.
    expect(prefs.getInt(MemoryMaintenanceService.lastRunKey),
        base.add(const Duration(minutes: 1)).millisecondsSinceEpoch);
  });

  test('prefs recallAgeDays is plumbed into the consolidator', () async {
    // Aging configured to 0 days: a 10-day-old recall fact is demoted.
    final prefs = await mockPrefs({
      MemoryMaintenanceService.recallAgeDaysKey: 0,
      MemoryStore.storageKey: jsonEncode([
        factJson('f1', '用户偏好简洁回复', daysAgo(10), tier: 'recall'),
      ]),
    });
    final store = MemoryStore(prefs);

    final report =
        await MemoryMaintenanceService(clock: () => base).runIfNeeded(store);
    expect(report?.demoted, 1);
    expect(store.loadFacts().single.tier, MemoryTier.archival);
  });

  test('prefs archivalCap is plumbed into the consolidator', () async {
    // Cap configured to 2: the oldest of three archival facts is evicted.
    final prefs = await mockPrefs({
      MemoryMaintenanceService.archivalCapKey: 2,
      MemoryStore.storageKey: jsonEncode([
        factJson('a1', '事实甲', daysAgo(30), tier: 'archival'),
        factJson('a2', '事实乙', daysAgo(20), tier: 'archival'),
        factJson('a3', '事实丙', daysAgo(10), tier: 'archival'),
      ]),
    });
    final store = MemoryStore(prefs);

    final report =
        await MemoryMaintenanceService(clock: () => base).runIfNeeded(store);
    expect(report?.evicted, 1);
    expect([for (final fact in store.loadFacts()) fact.id], ['a2', 'a3']);
  });

  test('defaults (45-day aging) apply when prefs keys are absent', () async {
    final prefs = await mockPrefs();
    final store = MemoryStore(prefs);
    await store.addFacts(['用户偏好简洁回复'], at: daysAgo(10));

    // A 10-day-old recall fact is well inside the default window.
    final service = MemoryMaintenanceService(clock: () => base);
    final report = await service.runIfNeeded(store);
    expect(report?.demoted, 0);
    expect(store.loadFacts().single.tier, MemoryTier.recall);

    // A fact older than the default 45 days is demoted — proof the default
    // came from the service, not from a prefs key.
    await store.addFacts(['用户喜欢深色主题'], at: daysAgo(46));
    final forced = await service.runIfNeeded(store, force: true);
    expect(forced?.demoted, 1);
    final tiers = {for (final fact in store.loadFacts()) fact.text: fact.tier};
    expect(tiers['用户偏好简洁回复'], MemoryTier.recall);
    expect(tiers['用户喜欢深色主题'], MemoryTier.archival);
  });

  test('corrupt prefs are swallowed into a null report', () async {
    // A wrong-typed last-run value makes getInt throw; the automatic path
    // must collapse to null instead of surfacing the error.
    final prefs = await mockPrefs({
      MemoryMaintenanceService.lastRunKey: 'not-a-number',
    });
    final store = MemoryStore(prefs);
    await store.addFacts(['用户偏好简洁回复'], at: daysAgo(1));

    final service = MemoryMaintenanceService(clock: () => base);
    expect(await service.runIfNeeded(store), isNull);

    // force skips the throttle read entirely, so the corrupt value is
    // irrelevant there and the pass runs normally.
    final forced = await service.runIfNeeded(store, force: true);
    expect(forced, isNotNull);
    expect(store.loadFacts().single.text, '用户偏好简洁回复');
  });
}
