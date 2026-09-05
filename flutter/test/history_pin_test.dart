import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/features/chat/conversation_actions.dart';
import 'package:shelly_hermes/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SettingsStore> freshStore() async =>
      SettingsStore(await SharedPreferences.getInstance());

  ConversationSummary summary(
    String id,
    String title,
    DateTime updatedAt,
  ) =>
      ConversationSummary(
        id: id,
        title: title,
        updatedAt: updatedAt,
        messageCount: 3,
      );

  testWidgets('pin entry toggles the pinned flag through the store',
      (tester) async {
    final store = await freshStore();
    await store.saveConversations([
      summary('conv-a', '普通会话', DateTime(2026, 9, 3)),
      summary('conv-b', '旧会话', DateTime(2026, 8, 1)),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWith((ref) => store),
        ],
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            return ElevatedButton(
              onPressed: () {
                // Mirrors the real sheets: the summary is reloaded from
                // the store before toggling so the flag flips per tap.
                final current = store
                    .loadConversations()
                    .firstWhere((c) => c.id == 'conv-a');
                toggleConversationPin(ref, store, current);
              },
              child: const Text('toggle-pin'),
            );
          }),
        ),
      ),
    );

    // First tap pins the conversation and persists the flag.
    await tester.tap(find.text('toggle-pin'));
    await tester.pumpAndSettle();
    expect(
      store.loadConversations().firstWhere((c) => c.id == 'conv-a').pinned,
      isTrue,
    );
    // The untouched conversation keeps its unpinned flag.
    expect(
      store.loadConversations().firstWhere((c) => c.id == 'conv-b').pinned,
      isFalse,
    );
    // Pinned conversations sort to the top of the history list.
    expect(sortConversations(store.loadConversations()).first.id, 'conv-a');

    // Tapping again unpins and clears the flag.
    await tester.tap(find.text('toggle-pin'));
    await tester.pumpAndSettle();
    expect(
      store.loadConversations().firstWhere((c) => c.id == 'conv-a').pinned,
      isFalse,
    );
  });

  testWidgets('history sheet shows the pin entry and persists the toggle',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    await store.saveConversations([
      summary('conv-new', '最新的会话', DateTime(2026, 9, 3)),
      summary('conv-old', '最早的会话', DateTime(2026, 8, 1)),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();

    // Long-pressing a conversation opens the management sheet with the
    // pin entry; the label reflects the current pinned state.
    await tester.longPress(find.text('最早的会话'));
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('取消置顶'), findsNothing);

    // Tapping the entry pins the conversation in the store.
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(
      store.loadConversations().firstWhere((c) => c.id == 'conv-old').pinned,
      isTrue,
    );

    // The tile marks the pinned conversation and sorts it above the
    // more recently updated one.
    expect(find.text('📌 最早的会话'), findsOneWidget);
    final tiles = tester
        .widgetList<ListTile>(find.descendant(
            of: find.byType(ListView), matching: find.byType(ListTile)))
        .toList();
    expect(tiles, isNotEmpty);
    expect((tiles.first.title as Text).data, '📌 最早的会话');

    // Long-pressing again offers the unpin entry, which clears the flag.
    await tester.longPress(find.text('📌 最早的会话'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();

    expect(
      store.loadConversations().firstWhere((c) => c.id == 'conv-old').pinned,
      isFalse,
    );
    expect(find.text('📌 最早的会话'), findsNothing);
  });
}
