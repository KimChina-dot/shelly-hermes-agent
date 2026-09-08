import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryStore JSON backup (PHASE 50)', () {
    test('exportJson writes a versioned envelope in the persisted shape',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          MemoryStore(await SharedPreferences.getInstance());
      await store.addFacts(
        ['用户偏好简洁的中文回复', '用户在上海工作'],
        sourceConversationId: 'conv-1',
        at: DateTime(2026, 9, 1, 12, 30),
      );
      final facts = store.loadFacts();
      await store.promote(facts.first.id, MemoryTier.core);
      await store.promote(facts.last.id, MemoryTier.archival);

      final envelope =
          jsonDecode(store.exportJson()) as Map<String, dynamic>;

      expect(envelope['version'], 1);
      expect(envelope['count'], 2);
      expect(DateTime.tryParse(envelope['exportedAt'] as String), isNotNull);
      final exported = envelope['facts'] as List<dynamic>;
      expect(exported, hasLength(2));
      // Per-fact shape matches persistence exactly (toJson), tiers ride
      // along: first fact was promoted to core, last to archival.
      final stored = store.loadFacts();
      expect(exported[0], stored[0].toJson());
      expect(exported[0]['tier'], 'core');
      expect(exported[1], stored[1].toJson());
      expect(exported[1]['tier'], 'archival');
    });

    test('export → import round-trip preserves tiers, counts and createdAt',
        () async {
      SharedPreferences.setMockInitialValues({});
      final source =
          MemoryStore(await SharedPreferences.getInstance());
      final added = await source.addFacts(
        ['用户偏好简洁的中文回复', '用户在上海工作', '喜欢喝手冲咖啡'],
        sourceConversationId: 'conv-9',
        at: DateTime(2026, 9, 1, 12, 30),
      );
      await source.promote(added[0].id, MemoryTier.core);
      await source.promote(added[1].id, MemoryTier.archival);
      final exported = source.exportJson();
      final expected = source.loadFacts();

      // A different device restores into a store that already holds a
      // local fact; replace mode must end up with exactly the backup.
      SharedPreferences.setMockInitialValues({
        MemoryStore.storageKey: jsonEncode([
          {
            'id': 'm-local',
            'text': '本地已有的事实',
            'createdAt': '2026-09-02T08:00:00.000',
          },
        ]),
      });
      final target =
          MemoryStore(await SharedPreferences.getInstance());
      final report = await target.importJson(exported);

      expect(
        report,
        const ImportReport(
            imported: 3, skippedDuplicates: 0, invalidEntries: 0),
      );
      expect(target.loadFacts(), expected);
      expect(target.loadFacts(), hasLength(3));
      expect(target.loadByTier(MemoryTier.core).single.text,
          '用户偏好简洁的中文回复');
      expect(target.loadByTier(MemoryTier.archival).single.text,
          '用户在上海工作');
      expect(
        target.loadFacts().map((fact) => fact.createdAt),
        everyElement(DateTime(2026, 9, 1, 12, 30)),
      );
      expect(
        target.loadFacts().map((fact) => fact.sourceConversationId),
        everyElement('conv-9'),
      );
      // Import persists: a fresh store over the same prefs sees it too.
      final reloaded =
          MemoryStore(await SharedPreferences.getInstance());
      expect(reloaded.loadFacts(), expected);
    });

    test('merge dedupes by normalized text and existing facts win', () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          MemoryStore(await SharedPreferences.getInstance());
      final existing = await store.addFacts(
        ['用户偏好简洁回复', '用户在上海工作'],
        at: DateTime(2026, 9, 1, 9, 0),
      );

      // The backup holds: an exact duplicate of the first fact (with a
      // different id, tier and timestamp — the local fact must win), a
      // whitespace-padded variant of the second one, one genuinely new
      // core-tier fact, and a within-file duplicate of that new fact.
      final backup = jsonEncode({
        'version': 1,
        'exportedAt': '2026-09-03T10:00:00.000',
        'count': 4,
        'facts': [
          {
            'id': 'm-from-backup-1',
            'text': '用户偏好简洁回复',
            'createdAt': '2026-09-03T08:00:00.000',
            'tier': 'core',
          },
          {
            'id': 'm-from-backup-2',
            'text': '  用户在上海工作  ',
            'createdAt': '2026-09-03T08:00:00.000',
          },
          {
            'id': 'm-from-backup-3',
            'text': '喜欢喝手冲咖啡',
            'createdAt': '2026-09-03T08:00:00.000',
            'tier': 'core',
          },
          {
            'id': 'm-from-backup-4',
            'text': '喜欢喝手冲咖啡',
            'createdAt': '2026-09-03T09:00:00.000',
          },
        ],
      });

      final report = await store.importJson(backup, merge: true);

      expect(
        report,
        const ImportReport(
            imported: 1, skippedDuplicates: 3, invalidEntries: 0),
      );
      final facts = store.loadFacts();
      expect(facts, hasLength(3));
      // Existing facts win: untouched id and timestamp even though the
      // backup claimed a different tier for the same text.
      expect(facts[0].id, existing[0].id);
      expect(facts[0].createdAt, DateTime(2026, 9, 1, 9, 0));
      expect(facts[0].tier, MemoryTier.recall);
      // New facts keep the imported tier and timestamp ("tier kept for
      // new ids").
      expect(facts[2].id, 'm-from-backup-3');
      expect(facts[2].tier, MemoryTier.core);
      expect(facts[2].createdAt, DateTime(2026, 9, 3, 8, 0));
    });

    test('invalid entries are counted and skipped', () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          MemoryStore(await SharedPreferences.getInstance());
      await store.addFacts(['原有事实'], at: DateTime(2026, 9, 1));

      final backup = jsonEncode({
        'version': 1,
        'exportedAt': '2026-09-03T10:00:00.000',
        'count': 6,
        'facts': [
          {
            'id': 'm-good',
            'text': '备份里的新事实',
            'createdAt': '2026-09-03T08:00:00.000',
          },
          'a bare string',
          42,
          null,
          {'id': 'm-blank', 'text': '   '},
          {'text': '缺少 id 的条目'},
        ],
      });

      final report = await store.importJson(backup, merge: true);

      expect(
        report,
        const ImportReport(
            imported: 1, skippedDuplicates: 0, invalidEntries: 5),
      );
      final facts = store.loadFacts();
      expect(facts, hasLength(2));
      expect(facts.map((fact) => fact.text),
          containsAll(['原有事实', '备份里的新事实']));
    });

    test('corrupt JSON surfaces as a FormatException and keeps the store',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          MemoryStore(await SharedPreferences.getInstance());
      await store.addFacts(['原有事实'], at: DateTime(2026, 9, 1));

      // Broken JSON syntax.
      await expectLater(
        store.importJson('not-json{'),
        throwsFormatException,
      );
      // Valid JSON, wrong envelope shape.
      await expectLater(
        store.importJson('[{"id":"m-a","text":"x"}]'),
        throwsFormatException,
      );
      // Envelope without a facts list.
      await expectLater(
        store.importJson('{"version": 1, "exportedAt": "2026-09-03"}'),
        throwsFormatException,
      );
      // Nothing above may have touched the persisted store.
      expect(store.loadFacts().single.text, '原有事实');
    });

    test('replace wipes the store while merge keeps local facts', () async {
      final backup = jsonEncode({
        'version': 1,
        'exportedAt': '2026-09-03T10:00:00.000',
        'count': 1,
        'facts': [
          {
            'id': 'm-backup-a',
            'text': '备份事实',
            'createdAt': '2026-09-03T08:00:00.000',
            'tier': 'archival',
          },
        ],
      });

      // Merge: the local fact survives, the backup fact lands with the
      // tier recorded in the file.
      SharedPreferences.setMockInitialValues({});
      final mergeStore =
          MemoryStore(await SharedPreferences.getInstance());
      await mergeStore.addFacts(['本地事实'], at: DateTime(2026, 9, 1));
      await mergeStore.importJson(backup, merge: true);
      expect(mergeStore.loadFacts().map((fact) => fact.text),
          ['本地事实', '备份事实']);
      expect(mergeStore.loadByTier(MemoryTier.archival).single.text,
          '备份事实');

      // Replace (default): only the backup remains.
      SharedPreferences.setMockInitialValues({});
      final replaceStore =
          MemoryStore(await SharedPreferences.getInstance());
      await replaceStore.addFacts(['本地事实'], at: DateTime(2026, 9, 1));
      await replaceStore.importJson(backup);
      expect(replaceStore.loadFacts().map((fact) => fact.text),
          ['备份事实']);
      expect(replaceStore.loadByTier(MemoryTier.archival), hasLength(1));
      expect(replaceStore.loadByTier(MemoryTier.recall), isEmpty);
    });
  });
}
