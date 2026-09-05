import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/features/history/history_page.dart';
import 'package:shelly_hermes/state/conversation_search.dart';
import 'package:shelly_hermes/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds a SettingsStore over mock prefs and fills it with two
/// conversations: one whose title mentions the login crash, one whose
/// first user message mentions a tetris game.
Future<SettingsStore> seedStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = SettingsStore(await SharedPreferences.getInstance());
  await store.saveCheckpoint(
    'conv-login',
    const AgentCheckpoint(
      messages: [AgentMessage(role: MessageRole.user, content: '修复登录页崩溃')],
      round: 1,
      consumedTokens: 0,
      toolCalls: 0,
    ),
  );
  await store.saveCheckpoint(
    'conv-game',
    const AgentCheckpoint(
      messages: [AgentMessage(role: MessageRole.user, content: '写一个俄罗斯方块小游戏')],
      round: 2,
      consumedTokens: 0,
      toolCalls: 0,
    ),
  );
  await store.saveConversations([
    ConversationSummary(
      id: 'conv-login',
      title: '登录崩溃排查',
      updatedAt: DateTime(2026, 9, 3, 12),
      messageCount: 4,
    ),
    ConversationSummary(
      id: 'conv-game',
      title: '游戏开发',
      updatedAt: DateTime(2026, 9, 4, 9),
      messageCount: 6,
    ),
  ]);
  return store;
}

AgentCheckpoint checkpointWithUserText(String text) => AgentCheckpoint(
  messages: [AgentMessage(role: MessageRole.user, content: text)],
  round: 1,
  consumedTokens: 0,
  toolCalls: 0,
);

void main() {
  group('searchConversations unit tests', () {
    test('blank query returns every conversation in history order', () async {
      final store = await seedStore();
      final results = searchConversations(store, '   ');
      expect(results.map((c) => c.id).toList(), ['conv-game', 'conv-login']);
    });

    test('matches title case-insensitively', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.saveConversations([
        ConversationSummary(
          id: 'a',
          title: 'Login Crash Hunt',
          updatedAt: DateTime(2026, 9, 1),
          messageCount: 2,
        ),
      ]);
      expect(searchConversations(store, 'login').map((c) => c.id), ['a']);
      expect(searchConversations(store, 'CRASH').map((c) => c.id), ['a']);
      expect(searchConversations(store, '登录'), isEmpty);
    });

    test('matches the first user message text', () async {
      final store = await seedStore();
      final results = searchConversations(store, '俄罗斯方块');
      expect(results.map((c) => c.id).toList(), ['conv-game']);
    });

    test('conversation without checkpoint never content-matches', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.saveConversations([
        ConversationSummary(
          id: 'bare',
          title: '无检查点会话',
          updatedAt: DateTime(2026, 9, 1),
          messageCount: 0,
        ),
      ]);
      expect(searchConversations(store, '无检查点'), isNotEmpty);
      expect(searchConversations(store, '检查点内容'), isEmpty);
    });

    test('no match returns an empty list', () async {
      final store = await seedStore();
      expect(searchConversations(store, '天气'), isEmpty);
    });

    test('title match outranks newer message-only match', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.saveCheckpoint(
        'older-title',
        checkpointWithUserText('完全无关的开场白'),
      );
      await store.saveCheckpoint(
        'newer-message',
        checkpointWithUserText('讨论一下部署方案'),
      );
      await store.saveConversations([
        ConversationSummary(
          id: 'older-title',
          title: '部署踩坑记录',
          updatedAt: DateTime(2026, 8, 1),
          messageCount: 3,
        ),
        ConversationSummary(
          id: 'newer-message',
          title: '随便聊聊',
          updatedAt: DateTime(2026, 9, 5),
          messageCount: 5,
        ),
      ]);
      final results = searchConversations(store, '部署');
      expect(results.map((c) => c.id).toList(), [
        'older-title',
        'newer-message',
      ]);
    });

    test('within a rank, most recently updated wins', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.saveCheckpoint('old', checkpointWithUserText('缓存失效问题'));
      await store.saveCheckpoint('new', checkpointWithUserText('缓存穿透问题'));
      await store.saveConversations([
        ConversationSummary(
          id: 'old',
          title: '八月的调试',
          updatedAt: DateTime(2026, 8, 15),
          messageCount: 2,
        ),
        ConversationSummary(
          id: 'new',
          title: '九月的调试',
          updatedAt: DateTime(2026, 9, 5),
          messageCount: 2,
        ),
      ]);
      final results = searchConversations(store, '缓存');
      expect(results.map((c) => c.id).toList(), ['new', 'old']);
    });

    test('limit caps result count but not blank-query results', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());
      await store.saveConversations([
        ConversationSummary(
          id: 'one',
          title: '笔记一',
          updatedAt: DateTime(2026, 9, 1),
          messageCount: 1,
        ),
        ConversationSummary(
          id: 'two',
          title: '笔记二',
          updatedAt: DateTime(2026, 9, 2),
          messageCount: 1,
        ),
        ConversationSummary(
          id: 'three',
          title: '笔记三',
          updatedAt: DateTime(2026, 9, 3),
          messageCount: 1,
        ),
      ]);
      expect(searchConversations(store, '笔记', limit: 2).length, 2);
      expect(searchConversations(store, '').length, 3);
    });
  });

  group('history page search widget tests', () {
    Future<void> pumpHistoryPage(
      WidgetTester tester,
      SettingsStore store,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsStoreProvider.overrideWith((ref) async => store)],
          child: MaterialApp(
            theme: buildShellyTheme(Brightness.light),
            home: const HistoryPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('search entry filters the conversation list', (tester) async {
      final store = await seedStore();
      await pumpHistoryPage(tester, store);

      expect(find.text('登录崩溃排查'), findsOneWidget);
      expect(find.text('游戏开发'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '崩溃');
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('登录崩溃排查'), findsOneWidget);
      expect(find.text('游戏开发'), findsNothing);
    });

    testWidgets('shows the no-match empty state', (tester) async {
      final store = await seedStore();
      await pumpHistoryPage(tester, store);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '不存在的关键词');
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('未找到匹配对话'), findsOneWidget);
      expect(find.text('登录崩溃排查'), findsNothing);
      expect(find.text('游戏开发'), findsNothing);
    });

    testWidgets(
      'matches by first message content and closes back to full list',
      (tester) async {
        final store = await seedStore();
        await pumpHistoryPage(tester, store);

        await tester.tap(find.byIcon(Icons.search));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '俄罗斯方块');
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('游戏开发'), findsOneWidget);
        expect(find.text('登录崩溃排查'), findsNothing);

        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pumpAndSettle();

        expect(find.text('登录崩溃排查'), findsOneWidget);
        expect(find.text('游戏开发'), findsOneWidget);
      },
    );
  });
}
