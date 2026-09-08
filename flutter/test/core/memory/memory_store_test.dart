import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryStore persistence', () {
    test('addFacts round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = MemoryStore(prefs);

      final at = DateTime(2026, 9, 6, 12, 30);
      final added = await store.addFacts(
        ['用户偏好简洁的中文回复'],
        sourceConversationId: 'conv-1',
        at: at,
      );

      expect(added, hasLength(1));
      expect(added.single.text, '用户偏好简洁的中文回复');
      expect(added.single.id, isNotEmpty);
      expect(added.single.createdAt, at);
      expect(added.single.sourceConversationId, 'conv-1');

      // A new instance over the same prefs sees the persisted fact.
      final reloaded = MemoryStore(await SharedPreferences.getInstance());
      expect(reloaded.loadFacts(), added);
    });

    test('facts without a conversation id persist with a null source',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      await store.addFacts(['用户在北京工作']);

      expect(store.loadFacts().single.sourceConversationId, isNull);
    });

    test('empty and blank texts never become facts', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final added = await store.addFacts(['', '   ']);

      expect(added, isEmpty);
      expect(store.loadFacts(), isEmpty);
    });

    test('a corrupt payload reads back as an empty store', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(MemoryStore.storageKey, 'not-json{');

      final store = MemoryStore(prefs);
      expect(store.loadFacts(), isEmpty);

      // The store recovers: new facts land on top of the wiped payload.
      await store.addFacts(['用户偏好茶']);
      expect(store.loadFacts().single.text, '用户偏好茶');
    });
  });

  group('MemoryStore dedupe', () {
    test('duplicates inside one batch collapse (case and whitespace)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final added = await store.addFacts([
        'User likes tea',
        '  User  likes\ntea  ',
        'USER LIKES TEA',
        '另一条事实',
      ]);

      expect(added.map((f) => f.text), ['User likes tea', '另一条事实']);
      expect(store.loadFacts(), hasLength(2));
    });

    test('re-learning a known fact is a no-op', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      await store.addFacts(['用户在上海工作']);
      final again = await store.addFacts(['  用户在上海工作  ']);
      final english = await store.addFacts(['User likes tea']);
      final shouting = await store.addFacts(['user LIKES  TEA']);

      expect(again, isEmpty);
      expect(english, hasLength(1));
      expect(shouting, isEmpty);
      expect(store.loadFacts(), hasLength(2));
    });
  });

  group('MemoryStore cap', () {
    test('caps stored facts at 200, keeping the newest', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      for (var i = 0; i < MemoryStore.maxFacts + 5; i += 1) {
        await store.addFacts(['事实$i']);
      }

      final facts = store.loadFacts();
      expect(facts, hasLength(MemoryStore.maxFacts));
      // The five oldest rounds (0..4) were evicted; the newest survive.
      expect(facts.first.text, '事实5');
      expect(facts.last.text, '事实${MemoryStore.maxFacts + 4}');
    });
  });

  group('MemoryFact tiers (PHASE 47)', () {
    test('new facts default to recall and round-trip through JSON',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final added = await store.addFacts(['用户偏好简洁回复']);
      expect(added.single.tier, MemoryTier.recall);

      final back = MemoryFact.fromJson(added.single.toJson());
      expect(back, added.single);
      expect(back.tier, MemoryTier.recall);
    });

    test('every tier round-trips through JSON', () {
      final at = DateTime.utc(2026, 9, 7, 8, 0);
      for (final tier in MemoryTier.values) {
        final fact = MemoryFact(
          id: 'f-${tier.name}',
          text: '事实',
          createdAt: at,
          tier: tier,
        );
        final back = MemoryFact.fromJson(fact.toJson());
        expect(back.tier, tier);
        expect(back, fact);
      }
    });

    test('pre-tier records (JSON without tier) load as recall', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        MemoryStore.storageKey,
        '[{"id":"legacy-1","text":"旧记录",'
        '"createdAt":"2025-01-01T00:00:00.000Z"}]',
      );

      final store = MemoryStore(prefs);
      expect(store.loadFacts().single.tier, MemoryTier.recall);
    });

    test('unknown tier names degrade to recall instead of throwing', () {
      final fact = MemoryFact.fromJson({
        'id': 'x',
        'text': '事实',
        'createdAt': '2025-01-01T00:00:00.000Z',
        'tier': 'urgent',
      });
      expect(fact.tier, MemoryTier.recall);
    });

    test('promote moves facts between tiers in both directions', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final id = (await store.addFacts(['用户偏好茶'])).single.id;

      // Promote to core.
      final core = await store.promote(id, MemoryTier.core);
      expect(core!.tier, MemoryTier.core);
      expect(core.text, '用户偏好茶');
      expect(store.loadByTier(MemoryTier.core).single.id, id);

      // Demote to archival — the same entry point, opposite direction.
      final archival = await store.promote(id, MemoryTier.archival);
      expect(archival!.tier, MemoryTier.archival);
      expect(store.loadByTier(MemoryTier.core), isEmpty);
      expect(store.loadByTier(MemoryTier.archival).single.id, id);

      // Unknown ids are a no-op.
      expect(await store.promote('missing', MemoryTier.core), isNull);

      // The tier survives a fresh store instance over the same prefs.
      final reloaded = MemoryStore(await SharedPreferences.getInstance());
      expect(reloaded.loadFacts().single.tier, MemoryTier.archival);
    });

    test('loadByTier partitions the store by tier, oldest first', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final added = await store.addFacts(['甲', '乙', '丙']);
      await store.promote(added[1].id, MemoryTier.core);
      await store.promote(added[2].id, MemoryTier.archival);

      expect(
        store.loadByTier(MemoryTier.core).map((f) => f.text),
        ['乙'],
      );
      expect(
        store.loadByTier(MemoryTier.archival).map((f) => f.text),
        ['丙'],
      );
      expect(
        store.loadByTier(MemoryTier.recall).map((f) => f.text),
        ['甲'],
      );
      expect(store.loadFacts(), hasLength(3));
    });

    test('core facts survive the 200 cap while oldest recall drops', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      // The oldest five facts get promoted to core: exempt from pruning.
      final coreFacts =
          await store.addFacts(['核心事实0', '核心事实1', '核心事实2', '核心事实3', '核心事实4']);
      for (final fact in coreFacts) {
        await store.promote(fact.id, MemoryTier.core);
      }

      // Overflow the cap with plain recall facts (5 + 210 = 215 total).
      for (var i = 0; i < MemoryStore.maxFacts + 10; i += 1) {
        await store.addFacts(['事实$i']);
      }

      final facts = store.loadFacts();
      // Core entries still count toward the hard cap.
      expect(facts, hasLength(MemoryStore.maxFacts));
      // The oldest entries in the store are core — yet they survived.
      expect(facts.take(5).every((f) => f.tier == MemoryTier.core), isTrue);
      expect(
        facts.take(5).map((f) => f.text),
        ['核心事实0', '核心事实1', '核心事实2', '核心事实3', '核心事实4'],
      );
      // The 15 oldest recall facts paid the overflow instead.
      final recall = facts.where((f) => f.tier == MemoryTier.recall).toList();
      expect(recall, hasLength(MemoryStore.maxFacts - 5));
      expect(recall.first.text, '事实15');
      expect(recall.last.text, '事实${MemoryStore.maxFacts + 9}');
    });

    test('an all-core overflow still respects the hard cap', () async {
      SharedPreferences.setMockInitialValues({});
      final store = MemoryStore(await SharedPreferences.getInstance());

      final facts = await store.addFacts([
        for (var i = 0; i < MemoryStore.maxFacts + 3; i += 1) '核心$i',
      ]);
      for (final fact in facts) {
        await store.promote(fact.id, MemoryTier.core);
      }

      expect(store.loadFacts(), hasLength(MemoryStore.maxFacts));
      expect(
        store.loadByTier(MemoryTier.core).first.text,
        '核心3',
      );
    });
  });

  group('systemPromptWithMemory tiers (PHASE 47)', () {
    MemoryFact fact(String id, String text, int minutes,
            {MemoryTier tier = MemoryTier.recall}) =>
        MemoryFact(
          id: id,
          text: text,
          createdAt: DateTime(2026, 1, 1).add(Duration(minutes: minutes)),
          tier: tier,
        );

    test('core first, then newest recall up to the cap; archival absent',
        () {
      final memories = <MemoryFact>[
        // 25 recall facts (oldest first): only the newest 18 fit.
        for (var i = 0; i < 25; i += 1) fact('r$i', '回忆$i', i),
        // Archival facts never auto-inject.
        fact('a1', '归档甲', 100, tier: MemoryTier.archival),
        fact('a2', '归档乙', 101, tier: MemoryTier.archival),
        // Core facts always inject and consume recall budget.
        fact('c1', '核心甲', 200, tier: MemoryTier.core),
        fact('c2', '核心乙', 201, tier: MemoryTier.core),
      ];

      final prompt =
          systemPromptWithMemory(persona: '你是 Shelly。', memories: memories)!;

      // Bullet lines keep the injected facts; matching on whole lines avoids
      // substring collisions between 回忆1 and 回忆10..回忆17.
      final bullets =
          prompt.split('\n').where((line) => line.startsWith('- ')).toList();
      // All 20 bullets: 2 core + 18 newest recall.
      expect(bullets, hasLength(20));
      expect(bullets.take(2), ['- 核心甲', '- 核心乙']);
      // The 7 oldest recall facts paid for the 2 core facts.
      for (var i = 0; i < 7; i += 1) {
        expect(bullets, isNot(contains('- 回忆$i')), reason: 'dropped 回忆$i');
      }
      for (var i = 7; i < 25; i += 1) {
        expect(bullets, contains('- 回忆$i'), reason: 'kept 回忆$i');
      }
      expect(bullets.any((line) => line.contains('归档')), isFalse);
      expect(prompt, isNot(contains('归档甲')));
      expect(prompt, isNot(contains('归档乙')));

      // Core bullets open the memory block, before any recall bullet.
      final firstCore = prompt.indexOf('- 核心甲');
      final secondCore = prompt.indexOf('- 核心乙');
      final firstRecall = prompt.indexOf('- 回忆');
      expect(firstCore, greaterThan(prompt.indexOf('长期记忆')));
      expect(secondCore, greaterThan(firstCore));
      expect(firstRecall, greaterThan(secondCore));
    });

    test('core facts inject uncapped and starve the recall budget', () {
      final memories = <MemoryFact>[
        for (var i = 0; i < memoryPromptCap + 5; i += 1)
          fact('c$i', '核心$i', i, tier: MemoryTier.core),
        fact('r1', '回忆甲', 900),
        fact('a1', '归档甲', 901, tier: MemoryTier.archival),
      ];

      final prompt =
          systemPromptWithMemory(persona: '你是 Shelly。', memories: memories)!;

      final bullets =
          prompt.split('\n').where((line) => line.startsWith('- ')).toList();
      // Core rides in fully, uncapped.
      expect(bullets, hasLength(memoryPromptCap + 5));
      expect(bullets.first, '- 核心0');
      expect(bullets.last, '- 核心${memoryPromptCap + 4}');
      // Core already fills past the cap, so recall has no budget left and
      // archival never injects.
      expect(bullets, isNot(contains('- 回忆甲')));
      expect(prompt, isNot(contains('归档甲')));
    });

    test('an archival-only store injects no memory block', () {
      final prompt = systemPromptWithMemory(
        persona: '你是 Shelly。',
        memories: [fact('a1', '归档甲', 0, tier: MemoryTier.archival)],
      );
      expect(prompt, isNotNull);
      expect(prompt, isNot(contains('长期记忆')));
    });
  });
}
