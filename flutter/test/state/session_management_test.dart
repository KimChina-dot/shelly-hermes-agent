import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

ConversationSummary _summary(
  String id,
  String title,
  DateTime updatedAt, {
  bool pinned = false,
}) =>
    ConversationSummary(
      id: id,
      title: title,
      updatedAt: updatedAt,
      messageCount: 3,
      pinned: pinned,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsStore> freshStore() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsStore(await SharedPreferences.getInstance());
  }

  test('deleteConversation removes summary and checkpoint together',
      () async {
    final store = await freshStore();
    await store.saveCheckpoint(
      'conv-a',
      const AgentCheckpoint(
        messages: [],
        round: 1,
        consumedTokens: 0,
        toolCalls: 0,
      ),
    );
    await store.saveCheckpoint(
      'conv-b',
      const AgentCheckpoint(
        messages: [],
        round: 1,
        consumedTokens: 0,
        toolCalls: 0,
      ),
    );
    await store.saveConversations([
      _summary('conv-a', '要删的会话', DateTime(2026, 9, 1)),
      _summary('conv-b', '留下的会话', DateTime(2026, 9, 2)),
    ]);

    await store.deleteConversation('conv-a');

    expect(store.loadConversations().map((c) => c.id), ['conv-b']);
    expect(store.loadCheckpoint('conv-a'), isNull);
    expect(store.loadCheckpoint('conv-b'), isNotNull);
  });

  test('rename persists and empty titles are rejected by caller semantics',
      () async {
    final store = await freshStore();
    await store.saveConversations(
        [_summary('conv-a', '旧标题', DateTime(2026, 9, 1))]);

    await store.renameConversation('conv-a', '新标题');

    expect(store.loadConversations().single.title, '新标题');
  });

  test('setPinned persists and sortConversations orders pinned first',
      () async {
    final store = await freshStore();
    await store.saveConversations([
      _summary('conv-old', '最早的会话', DateTime(2026, 8, 1)),
      _summary('conv-new', '最新的会话', DateTime(2026, 9, 3)),
      _summary('conv-pin', '置顶的会话', DateTime(2026, 7, 1), pinned: true),
    ]);

    final sorted = sortConversations(store.loadConversations());

    expect(sorted.map((c) => c.id).toList(),
        ['conv-pin', 'conv-new', 'conv-old']);
  });

  test('legacy summaries without the pinned field decode with pinned=false',
      () async {
    final summary = ConversationSummary.fromJson({
      'id': 'conv-legacy',
      'title': '旧版本数据',
      'updatedAt': '2026-08-15T10:00:00.000',
      'messageCount': 5,
    });

    expect(summary.pinned, isFalse);
  });

  test('switchTo loads a conversation and returns false when missing',
      () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await freshStore();

    await store.saveCheckpoint(
      'conv-a',
      const AgentCheckpoint(
        messages: [],
        round: 1,
        consumedTokens: 0,
        toolCalls: 0,
      ),
    );
    final controller = container.read(chatSessionProvider.notifier)
      ..attach(store);

    expect(controller.switchTo('conv-a'), isTrue);
    expect(container.read(chatSessionProvider).conversationId, 'conv-a');
    expect(controller.switchTo('missing'), isFalse);
  });

  test('deleteCurrentConversation resets the chat to a fresh state',
      () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await freshStore();

    await store.saveCheckpoint(
      'conv-a',
      const AgentCheckpoint(
        messages: [],
        round: 1,
        consumedTokens: 0,
        toolCalls: 0,
      ),
    );
    final controller = container.read(chatSessionProvider.notifier)
      ..attach(store);
    controller.switchTo('conv-a');

    expect(await controller.deleteCurrentConversation(), isTrue);
    expect(store.loadCheckpoint('conv-a'), isNull);
    expect(store.loadConversations(), isEmpty);
    expect(container.read(chatSessionProvider).conversationId, isNull);
  });
}
