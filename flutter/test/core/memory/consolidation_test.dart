import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/memory/consolidation.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed anchor for the injectable clock, so aging is deterministic.
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

  Future<void> seed(
    SharedPreferences prefs,
    List<Map<String, dynamic>> entries,
  ) =>
      prefs.setString(MemoryStore.storageKey, jsonEncode(entries));

  Future<List<Map<String, dynamic>>> persisted(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(MemoryStore.storageKey);
    if (raw == null) return const [];
    return [
      for (final entry in jsonDecode(raw) as List<dynamic>)
        Map<String, dynamic>.from(entry as Map<dynamic, dynamic>),
    ];
  }

  MemoryConsolidator consolidator({
    Future<String?> Function(List<MemoryFact> group)? summarizer,
    int recallAgeDays = 45,
    int archivalCap = 300,
  }) =>
      MemoryConsolidator(
        clock: () => base,
        summarizer: summarizer,
        recallAgeDays: recallAgeDays,
        archivalCap: archivalCap,
      );

  group('MemoryConsolidator', () {
    test('empty store is a no-op with an all-zero report', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);

      final report = await consolidator().consolidate(store);

      expect(report, const ConsolidationReport());
      expect(prefs.getString(MemoryStore.storageKey), isNull);
    });

    test('merges near-duplicates above the Jaccard threshold', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      // Similar enough (token Jaccard 8/13 ~ 0.62): the newer fact survives
      // with the older, SHORTER text and the newer's createdAt.
      await seed(prefs, [
        factJson('f-old', '用户喜欢简洁回复', daysAgo(2)),
        factJson('f-new', '用户喜欢简洁的中文回复风格', daysAgo(1)),
      ]);

      final report = await consolidator().consolidate(store);

      expect(
        report,
        const ConsolidationReport(merged: 1),
      );
      final entries = await persisted(prefs);
      expect(entries, hasLength(1));
      expect(entries.single['id'], 'f-new');
      expect(entries.single['text'], '用户喜欢简洁回复');
      expect(
        entries.single['createdAt'],
        daysAgo(1).toIso8601String(),
      );
      expect(entries.single['tier'], 'recall');
    });

    test('keeps dissimilar facts below the threshold untouched', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      final seeded = [
        factJson('f-1', '用户喜欢简洁回复', daysAgo(2)),
        factJson('f-2', '用户在上海浦东工作', daysAgo(1)),
      ];
      await seed(prefs, seeded);

      final report = await consolidator().consolidate(store);

      expect(report, const ConsolidationReport());
      // All-zero passes must not rewrite storage at all.
      expect(
        prefs.getString(MemoryStore.storageKey),
        jsonEncode(seeded),
      );
    });

    test('never merges facts across tiers', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      // Near-identical texts, but different tiers: no merge.
      await seed(prefs, [
        factJson('f-core', '用户偏好简洁的中文回复', daysAgo(2), tier: 'core'),
        factJson('f-arch', '用户偏好简洁中文回复', daysAgo(1), tier: 'archival'),
        factJson('f-aged', '用户每周三去健身房', daysAgo(46)),
      ]);

      final report = await consolidator().consolidate(store);

      expect(report, const ConsolidationReport(demoted: 1));
      final entries = await persisted(prefs);
      expect(entries, hasLength(3));
      final tierOf = {for (final e in entries) e['id'] as String: e['tier']};
      expect(tierOf['f-core'], 'core');
      expect(tierOf['f-arch'], 'archival');
      expect(tierOf['f-aged'], 'archival');
    });

    test('demotes recall facts past the aging threshold to archival',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      await seed(prefs, [
        // Strictly older than 45 days: demoted.
        factJson('f-aged', '用户偏好简洁回复', daysAgo(46)),
        // Exactly at the threshold: not demoted (strictly-greater rule).
        factJson('f-edge', '用户在上海浦东工作', daysAgo(45)),
        factJson('f-young', '用户养了一只橘猫', daysAgo(1)),
      ]);

      final report = await consolidator().consolidate(store);

      expect(report, const ConsolidationReport(demoted: 1));
      final entries = await persisted(prefs);
      final tierOf = {for (final e in entries) e['id'] as String: e['tier']};
      expect(tierOf['f-aged'], 'archival');
      expect(tierOf['f-edge'], 'recall');
      expect(tierOf['f-young'], 'recall');
    });

    test('caps the archival tier, evicting the oldest first', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      // Five mutually dissimilar archival facts; the two oldest overflow the
      // cap of 3 and are evicted, oldest first.
      const texts = [
        '用户养了一只橘猫',
        '用户每周三去健身房',
        '用户在上海浦东工作',
        '用户喜欢深夜编程',
        '用户会弹一点吉他',
      ];
      await seed(prefs, [
        for (var i = 0; i < texts.length; i++)
          factJson('f-$i', texts[i], daysAgo((i + 1) * 10), tier: 'archival'),
      ]);

      final report = await consolidator(archivalCap: 3).consolidate(store);

      expect(
        report,
        const ConsolidationReport(evicted: 2),
      );
      final entries = await persisted(prefs);
      expect([for (final e in entries) e['id']], ['f-0', 'f-1', 'f-2']);
      expect(
        [for (final e in entries) e['tier']],
        everyElement('archival'),
      );
    });

    test('replaces a large merge group with one synthesized fact', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      const texts = [
        '用户偏好简洁的中文回复',
        '用户偏好简洁中文回复',
        '用户喜欢简洁中文回复',
      ];
      await seed(prefs, [
        factJson('f-a', texts[0], daysAgo(3)),
        factJson('f-b', texts[1], daysAgo(2)),
        factJson('f-c', texts[2], daysAgo(1)),
      ]);
      var summarizedWith = <MemoryFact>[];

      final report = await consolidator(summarizer: (group) async {
        summarizedWith = List.of(group);
        return '用户偏好简洁的回复风格';
      }).consolidate(store);

      expect(
        report,
        const ConsolidationReport(merged: 2, synthesized: 1),
      );
      expect(summarizedWith, hasLength(3));
      expect(
        {for (final fact in summarizedWith) fact.text},
        texts.toSet(),
      );
      final entries = await persisted(prefs);
      expect(entries, hasLength(1));
      // The synthesized fact replaces the whole group, keeping the newest
      // member's identity and createdAt.
      expect(entries.single['id'], 'f-c');
      expect(entries.single['text'], '用户偏好简洁的回复风格');
      expect(entries.single['createdAt'], daysAgo(1).toIso8601String());
      expect(entries.single['tier'], 'recall');
    });

    test('keeps the merge result when the summarizer fails', () async {
      final flavors = <Future<String?> Function(List<MemoryFact> group)>[
        (_) async => throw Exception('gateway down'),
        (_) async => null,
        (_) async => '   ',
      ];
      for (final summarizer in flavors) {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = MemoryStore(prefs);
        await seed(prefs, [
          factJson('f-a', '用户偏好简洁的中文回复', daysAgo(3)),
          factJson('f-b', '用户偏好简洁中文回复', daysAgo(2)),
          factJson('f-c', '用户喜欢简洁中文回复', daysAgo(1)),
        ]);

        // Failure, null and blank replies all fall back to the merge result:
        // the three facts fold into one carrying the shortest text.
        final report = await consolidator(summarizer: summarizer)
            .consolidate(store);

        expect(report, const ConsolidationReport(merged: 2));
        final entries = await persisted(prefs);
        expect(entries, hasLength(1));
        expect(entries.single['id'], 'f-c');
        expect(entries.single['text'], '用户偏好简洁中文回复');
        expect(entries.single['tier'], 'recall');
      }
    });

    test('does not call the summarizer for two-fact groups', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      await seed(prefs, [
        factJson('f-a', '用户偏好简洁的中文回复', daysAgo(2)),
        factJson('f-b', '用户偏好简洁中文回复', daysAgo(1)),
      ]);
      var called = false;

      final report = await consolidator(summarizer: (group) async {
        called = true;
        return '不该出现的事实';
      }).consolidate(store);

      expect(called, isFalse);
      expect(report, const ConsolidationReport(merged: 1));
      final entries = await persisted(prefs);
      expect(entries.single['text'], '用户偏好简洁中文回复');
    });

    test('reports merged, demoted and evicted counts in one pass', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      await seed(prefs, [
        // Near-duplicate old pair: merges, then the survivor (49 days old)
        // ages out into archival, where the cap of 1 evicts the oldest.
        factJson('p-1', '用户偏好深夜编程', daysAgo(50)),
        factJson('p-2', '用户偏好深夜编程与咖啡', daysAgo(49)),
        factJson('q-1', '用户养了一只橘猫', daysAgo(60), tier: 'archival'),
        factJson('r-1', '用户每周三去健身房', daysAgo(1)),
      ]);

      final report = await consolidator(archivalCap: 1).consolidate(store);

      expect(
        report,
        const ConsolidationReport(merged: 1, demoted: 1, evicted: 1),
      );
      final entries = await persisted(prefs);
      final byId = {for (final e in entries) e['id'] as String: e};
      expect(byId.keys, ['p-2', 'r-1']);
      expect(byId['p-2']!['tier'], 'archival');
      expect(byId['p-2']!['text'], '用户偏好深夜编程');
      expect(byId['r-1']!['tier'], 'recall');
    });

    test('keeps facts learned while the pass was running', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);
      await seed(prefs, [
        factJson('f-a', '用户偏好简洁的中文回复', daysAgo(3)),
        factJson('f-b', '用户偏好简洁中文回复', daysAgo(2)),
        factJson('f-c', '用户喜欢简洁中文回复', daysAgo(1)),
      ]);

      final report = await consolidator(summarizer: (group) async {
        // The chat loop learns a fact while the summarizer call is in
        // flight; the rewrite must not clobber it.
        await store.addFacts(['用户在杭州工作']);
        return '用户偏好简洁的回复风格';
      }).consolidate(store);

      expect(
        report,
        const ConsolidationReport(merged: 2, synthesized: 1),
      );
      final entries = await persisted(prefs);
      final ids = [for (final e in entries) e['id'] as String];
      expect(ids, contains('f-c'));
      final texts = {for (final e in entries) e['text'] as String};
      expect(texts, containsAll(['用户偏好简洁的回复风格', '用户在杭州工作']));
    });
  });
}
