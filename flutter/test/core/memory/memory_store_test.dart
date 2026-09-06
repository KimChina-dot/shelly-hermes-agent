import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/memory/memory_store.dart';

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
}
