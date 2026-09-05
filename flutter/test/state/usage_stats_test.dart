import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';
import 'package:shelly_hermes/state/usage_stats.dart';

UsageEntry _entry(String modelId, int prompt, int completion, DateTime at) =>
    UsageEntry(
      modelId: modelId,
      promptTokens: prompt,
      completionTokens: completion,
      at: at,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UsageStatsStore persistence', () {
    test('recordUsage round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = UsageStatsStore(prefs);

      final at = DateTime(2026, 9, 1, 12, 30);
      await store.recordUsage(
        modelId: 'deepseek-chat',
        promptTokens: 120,
        completionTokens: 80,
        at: at,
      );

      // A new instance over the same prefs sees the persisted entry.
      final reloaded = UsageStatsStore(await SharedPreferences.getInstance());
      expect(reloaded.loadEntries(), [
        _entry('deepseek-chat', 120, 80, at),
      ]);
    });

    test('empty store yields no entries and zero totals', () async {
      SharedPreferences.setMockInitialValues({});
      final store = UsageStatsStore(await SharedPreferences.getInstance());

      expect(store.loadEntries(), isEmpty);
      expect(store.totals().totalTokens, 0);
      expect(store.totals().rounds, 0);
      expect(store.totalsByModel(), isEmpty);
      expect(store.totalsByDay(), isEmpty);
    });
  });

  group('UsageStatsStore aggregation', () {
    test('totals split by model with prompt/completion sums', () async {
      SharedPreferences.setMockInitialValues({});
      final store = UsageStatsStore(await SharedPreferences.getInstance());
      final day = DateTime(2026, 9, 2, 9);

      await store.recordUsage(
          modelId: 'model-a', promptTokens: 100, completionTokens: 50, at: day);
      await store.recordUsage(
          modelId: 'model-a', promptTokens: 10, completionTokens: 5, at: day);
      await store.recordUsage(
          modelId: 'model-b', promptTokens: 7, completionTokens: 3, at: day);

      final byModel = store.totalsByModel();
      expect(byModel.keys, hasLength(2));
      expect(byModel['model-a']!.promptTokens, 110);
      expect(byModel['model-a']!.completionTokens, 55);
      expect(byModel['model-a']!.rounds, 2);
      expect(byModel['model-b']!.totalTokens, 10);
      expect(byModel['model-b']!.rounds, 1);

      final totals = store.totals();
      expect(totals.promptTokens, 117);
      expect(totals.completionTokens, 58);
      expect(totals.totalTokens, 175);
      expect(totals.rounds, 3);
    });

    test('totals by day bucket local calendar dates', () async {
      SharedPreferences.setMockInitialValues({});
      final store = UsageStatsStore(await SharedPreferences.getInstance());

      await store.recordUsage(
        modelId: 'model-a',
        promptTokens: 10,
        completionTokens: 1,
        at: DateTime(2026, 9, 1, 23, 59),
      );
      await store.recordUsage(
        modelId: 'model-a',
        promptTokens: 20,
        completionTokens: 2,
        at: DateTime(2026, 9, 2, 0, 1),
      );

      final byDay = store.totalsByDay();
      expect(byDay.keys, hasLength(2));
      expect(byDay['2026-09-01']!.totalTokens, 11);
      expect(byDay['2026-09-02']!.totalTokens, 22);
    });
  });

  group('UsageStatsStore retention', () {
    test('prunes entries older than 30 days', () async {
      SharedPreferences.setMockInitialValues({});
      final store = UsageStatsStore(await SharedPreferences.getInstance());
      final now = DateTime(2026, 9, 6);

      await store.recordUsage(
        modelId: 'model-a',
        promptTokens: 1,
        completionTokens: 1,
        at: now.subtract(const Duration(days: 31)),
      );
      await store.recordUsage(
        modelId: 'model-a',
        promptTokens: 2,
        completionTokens: 2,
        at: now.subtract(const Duration(days: 29)),
      );

      final entries = store.loadEntries();
      expect(entries, hasLength(1));
      expect(entries.single.promptTokens, 2);
      expect(store.totals().totalTokens, 4);
    });

    test('caps stored entries at 1000, keeping the newest', () async {
      SharedPreferences.setMockInitialValues({});
      final store = UsageStatsStore(await SharedPreferences.getInstance());
      final now = DateTime(2026, 9, 6);

      for (var i = 0; i < UsageStatsStore.maxEntries + 5; i += 1) {
        await store.recordUsage(
          modelId: 'model-a',
          promptTokens: i,
          completionTokens: 0,
          at: now.add(Duration(minutes: i)),
        );
      }

      final entries = store.loadEntries();
      expect(entries, hasLength(UsageStatsStore.maxEntries));
      // The five oldest rounds (0..4) were evicted; the newest survive.
      expect(entries.first.promptTokens, 5);
      expect(entries.last.promptTokens, UsageStatsStore.maxEntries + 4);
    });
  });

  group('chat session usage recording', () {
    test('records every completed demo round into the usage store',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final store = SettingsStore(await SharedPreferences.getInstance());
      final controller = container.read(chatSessionProvider.notifier);
      controller.attach(store);

      // The demo gateway is the scripted fake for unconfigured endpoints:
      // '演示工具' runs one tool round plus one final reply round.
      await controller.send('演示工具');
      final usage = UsageStatsStore(await SharedPreferences.getInstance());
      for (var i = 0; i < 250; i += 1) {
        if (usage.loadEntries().length >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(container.read(chatSessionProvider).phase, SessionPhase.idle);
      final entries = usage.loadEntries();
      // One entry per completed model round: the tool round and the reply.
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.modelId == 'demo'), isTrue);
      // Rounds aggregate into the same totals the profile page reads.
      expect(usage.totals().rounds, 2);
      expect(usage.totalsByModel()['demo']!.rounds, 2);
    });
  });
}
