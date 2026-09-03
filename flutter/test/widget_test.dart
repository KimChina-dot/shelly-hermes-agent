import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/features/memory/memory_settings_page.dart';
import 'package:shelly_hermes/core/task_recovery.dart';
import 'package:shelly_hermes/design/components/tool_card.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app shell renders chat tab and bottom navigation', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    expect(find.text('你好,我是 Shelly'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('能力'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('给 Shelly 发送消息…'), findsOneWidget);
  });

  testWidgets('bottom navigation switches to capabilities tab', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();

    expect(find.text('工作区工具'), findsOneWidget);
    expect(find.text('apply_patch'), findsOneWidget);
  });

  testWidgets('capabilities tab hosts the DSH plugin installer', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('插件(DSH)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('插件(DSH)'), findsOneWidget);
    expect(find.text('安装插件'), findsOneWidget);
  });

  testWidgets('capabilities tab shows the plugin trust section', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('能力'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('插件工具信任'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    // No plugin is enabled in a fresh install: the fail-closed empty state.
    expect(find.text('插件工具信任'), findsOneWidget);
    expect(find.textContaining('尚未启用任何插件工具'), findsOneWidget);
  });

  testWidgets('tool card shows the plugin badge for DSH tools', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildShellyTheme(Brightness.dark),
        home: Scaffold(
          body: ListView(
            children: [
              ToolCard(
                entry: ToolEntry(
                  call: const ToolCall(
                    id: 't1',
                    name: 'vendor_build',
                    argumentsJson: '{"target":"lib/main.dart"}',
                  ),
                  status: ToolRunStatus.succeeded,
                )
                  ..result = 'risk=medium\nok'
                  ..durationMillis = 12,
                isPlugin: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('vendor_build'), findsOneWidget);
    expect(find.text('插件'), findsOneWidget);
  });

  testWidgets('history tab surfaces the interrupted task banner',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    const checkpoint = AgentCheckpoint(
      messages: [AgentMessage(role: MessageRole.user, content: '修复登录页崩溃')],
      round: 1,
      consumedTokens: 0,
      toolCalls: 0,
    );
    await store.saveCheckpoint('conv-recover', checkpoint);
    await store.saveActiveTask(TaskRecoveryRecord(
      conversationId: 'conv-recover',
      taskId: 'task-1',
      startedAt: DateTime(2026, 9, 3),
    ));

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();

    expect(find.text('有一个任务在后台被中断'), findsOneWidget);
    expect(find.text('恢复任务'), findsOneWidget);
    expect(find.text('忽略'), findsOneWidget);

    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();

    expect(find.text('有一个任务在后台被中断'), findsNothing);
    expect(find.text('还没有历史对话'), findsOneWidget);
  });

  testWidgets('profile tab shows agent profiles and provider presets',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('Agent 档案'), findsOneWidget);
    expect(find.text('平衡助手'), findsOneWidget);
    expect(find.text('获取模型列表'), findsOneWidget);
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('Ollama(本机)'), findsOneWidget);
  });

  testWidgets('profile tab opens the Hermes memory page', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('记忆(Hermes)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('记忆(Hermes)'));
    await tester.pumpAndSettle();

    // Fresh install: the ledger exists but has no entries yet.
    expect(find.text('账本条目'), findsOneWidget);
    expect(find.textContaining('还没有记住任何东西'), findsOneWidget);
    expect(find.textContaining('遗忘规则'), findsOneWidget);
  });

  testWidgets('profile tab switches agent profile on tap', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('谨慎工程师'));
    await tester.pumpAndSettle();

    // The tapped profile renders its meta line.
    expect(find.textContaining('24 轮'), findsOneWidget);
  });

  testWidgets('chat header opens the session sheet with saved conversations',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    await store.saveCheckpoint(
      'conv-1',
      const AgentCheckpoint(
        messages: [],
        round: 1,
        consumedTokens: 0,
        toolCalls: 0,
      ),
    );
    await store.saveConversations([
      ConversationSummary(
        id: 'conv-1',
        title: '修复登录页崩溃',
        updatedAt: DateTime(2026, 9, 3, 12),
        messageCount: 4,
      ),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    // Tap the header title area to open the session sheet.
    await tester.tap(find.text('Shelly'));
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('修复登录页崩溃'), findsOneWidget);
    expect(find.text('新会话'), findsOneWidget);
    expect(find.textContaining('4 条消息'), findsOneWidget);

    // Switch to the saved conversation; the sheet closes and the chat page
    // shows its title in the header.
    await tester.tap(find.text('修复登录页崩溃'));
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsNothing);
    expect(find.text('修复登录页崩溃'), findsOneWidget);
  });

  testWidgets('model chip opens the picker and applies a model config',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    // A key alone leaves the config incomplete, so the chip still offers
    // model selection, but applying a model then completes the config.
    await store.saveModelConfig(const ModelConfig(apiKey: 'sk-test'));

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    // Fresh install: the chip offers model selection.
    expect(find.text('选择模型'), findsOneWidget);

    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();

    expect(find.text('切换模型'), findsOneWidget);

    // The chat composer is also a TextField — locate the sheet fields by
    // their hint texts instead of tree order.
    final baseUrlField = find.byWidgetPredicate((w) =>
        w is TextField && (w.decoration?.hintText?.startsWith('https') ?? false));
    final modelField = find.byWidgetPredicate((w) =>
        w is TextField && (w.decoration?.hintText?.contains('deepseek-chat') ?? false));
    await tester.enterText(baseUrlField, 'https://api.deepseek.com/v1');
    await tester.enterText(modelField, 'deepseek-chat');
    await tester.pump();

    await tester.tap(find.text('使用此模型'));
    await tester.pumpAndSettle();

    // The sheet closes and the chip reflects the applied model.
    final applied = container.read(settingsStoreProvider).value!;
    expect(applied.modelConfig.model, 'deepseek-chat');
    expect(find.text('deepseek-chat'), findsOneWidget);
  });

  testWidgets('memory page runs manual upkeep and opens memory settings',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('记忆(Hermes)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('记忆(Hermes)'));
    await tester.pumpAndSettle();

    // The state card shows the raised default budget.
    expect(find.textContaining('/ 16000 token'), findsOneWidget);

    // Manual upkeep runs and shows its report even on an empty ledger.
    await tester.tap(find.text('立即整理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('整理完成'), findsOneWidget);

    // Settings page: adjust the ledger budget and save.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('存储预算'), findsOneWidget);
    expect(find.text('召回预算'), findsOneWidget);

    await tester.drag(find.byType(Slider).first, const Offset(120, 0));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('已保存'), findsOneWidget);
    final store = ProviderScope.containerOf(
            tester.element(find.byType(MemorySettingsPage)))
        .read(settingsStoreProvider)
        .value!;
    expect(store.loadMemorySettings().maxLedgerTokens, isNot(16000));
  });
}
