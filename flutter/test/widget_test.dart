import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/features/memory/memory_settings_page.dart';
import 'package:shelly_hermes/core/task_recovery.dart';
import 'package:shelly_hermes/design/components/tool_card.dart';
import 'package:shelly_hermes/design/theme.dart';
import 'package:shelly_hermes/features/chat/chat_page.dart'
    show
        createSpeechTranscriber,
        pickGalleryImage,
        pickTextFile,
        resetGalleryImagePicker,
        resetSpeechTranscriber,
        resetTextFilePicker;
import 'package:shelly_hermes/platform/speech.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('app shell renders chat tab and bottom navigation', (
    tester,
  ) async {
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

  testWidgets('capabilities tab hosts the DSH plugin installer', (
    tester,
  ) async {
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

  testWidgets('capabilities tab shows the plugin trust section', (
    tester,
  ) async {
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
                entry:
                    ToolEntry(
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

  testWidgets('history tab surfaces the interrupted task banner', (
    tester,
  ) async {
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
    await store.saveActiveTask(
      TaskRecoveryRecord(
        conversationId: 'conv-recover',
        taskId: 'task-1',
        startedAt: DateTime(2026, 9, 3),
      ),
    );

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

  testWidgets('profile tab shows agent profiles and provider presets', (
    tester,
  ) async {
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

  testWidgets('chat header opens the session sheet with saved conversations', (
    tester,
  ) async {
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

  testWidgets('model chip opens the picker and applies a model config', (
    tester,
  ) async {
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
    final baseUrlField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText?.startsWith('https') ?? false),
    );
    final modelField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText?.contains('deepseek-chat') ?? false),
    );
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

  testWidgets('web search toggle shows only for supporting providers', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = await container.read(settingsStoreProvider.future);
    await store.saveModelConfig(const ModelConfig(apiKey: 'sk-test'));

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();

    final baseUrlField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText?.startsWith('https') ?? false),
    );
    final modelField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.decoration?.hintText?.contains('deepseek-chat') ?? false),
    );

    // DeepSeek has no server-side search plugin — no toggle.
    await tester.enterText(baseUrlField, 'https://api.deepseek.com/v1');
    await tester.pump();
    expect(find.text('联网搜索'), findsNothing);

    // Zhipu exposes one; flipping it on persists with the config.
    await tester.enterText(
      baseUrlField,
      'https://open.bigmodel.cn/api/paas/v4',
    );
    await tester.pump();
    expect(find.text('联网搜索'), findsOneWidget);
    await tester.tap(find.text('联网搜索'));
    await tester.pump();

    await tester.enterText(modelField, 'glm-4.6');
    await tester.pump();
    await tester.tap(find.text('使用此模型'));
    await tester.pumpAndSettle();

    final applied = container.read(settingsStoreProvider).value!;
    expect(applied.modelConfig.model, 'glm-4.6');
    expect(applied.modelConfig.webSearchEnabled, isTrue);
  });

  testWidgets('hold-to-talk inserts the recognized transcript', (tester) async {
    addTearDown(resetSpeechTranscriber);
    createSpeechTranscriber = () => _FakeSpeech();

    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    final mic = find.byTooltip('按住说话');
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('帮我把会议纪要整理成待办'), findsOneWidget);
  });

  testWidgets('dictation shows a hint when speech is unavailable', (
    tester,
  ) async {
    addTearDown(resetSpeechTranscriber);
    createSpeechTranscriber = () => _UnavailableSpeech();

    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    final mic = find.byTooltip('按住说话');
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.textContaining('语音输入不可用'), findsOneWidget);
  });

  testWidgets('memory page runs manual upkeep and opens memory settings', (
    tester,
  ) async {
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
      tester.element(find.byType(MemorySettingsPage)),
    ).read(settingsStoreProvider).value!;
    expect(store.loadMemorySettings().maxLedgerTokens, isNot(16000));
  });

  testWidgets('profile page creates a custom profile', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建档案'));
    await tester.pumpAndSettle();

    final nameField = find.byWidgetPredicate(
      (w) =>
          w is TextField && (w.decoration?.hintText?.startsWith('例如') ?? false),
    );
    await tester.enterText(nameField, '深度调试助手');
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // The sheet closes; the new profile shows up in the list and is active.
    expect(find.text('深度调试助手'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text('深度调试助手')),
    );
    final store = container.read(settingsStoreProvider).value!;
    expect(store.activeProfile().name, '深度调试助手');
  });

  testWidgets('editing a preset copies it instead of mutating it', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    // Tap the copy affordance on the 谨慎工程师 preset row.
    final row = find
        .ancestor(of: find.text('谨慎工程师'), matching: find.byType(InkWell))
        .first;
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.copy_rounded)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('保存'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.text('谨慎工程师(自定义)')),
    );
    final store = container.read(settingsStoreProvider).value!;
    // The copy is active and the original preset list is intact.
    expect(store.activeProfile().name, '谨慎工程师(自定义)');
    expect(store.loadProfiles().where((p) => p.id == 'careful').length, 1);
  });

  testWidgets('composer attaches a gallery image and sends it with the message', (
    tester,
  ) async {
    const pngDataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    pickGalleryImage = () async => pngDataUrl;
    addTearDown(() {
      resetGalleryImagePicker();
    });

    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加图片或文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加图片(相册)'));
    await tester.pumpAndSettle();

    // The pending image shows as a removable thumbnail above the input.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);

    await tester.enterText(find.byType(TextField), '看看这张图');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // The message bubble renders the image; the pending strip is cleared.
    // The user text shows twice: in the bubble and as the auto conversation
    // title the demo run persists after finishing.
    expect(find.text('看看这张图'), findsNWidgets(2));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('attaching more than the image cap is rejected', (tester) async {
    const pngDataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    pickGalleryImage = () async => pngDataUrl;
    addTearDown(() {
      resetGalleryImagePicker();
    });

    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i += 1) {
      await tester.tap(find.byTooltip('添加图片或文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加图片(相册)'));
      await tester.pumpAndSettle();
    }

    expect(find.text('一条消息最多带 4 张图片'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(4));
  });

  testWidgets('composer attaches a text file and sends it with the message', (
    tester,
  ) async {
    pickTextFile = () async =>
        const TextFileAttachment(name: 'notes.md', content: '第 1 行\n第 2 行');
    addTearDown(resetTextFilePicker);

    await tester.pumpWidget(const ProviderScope(child: ShellyApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加图片或文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加文件(文本/代码,≤200KB)'));
    await tester.pumpAndSettle();

    // The pending file shows as a removable chip above the input.
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.byType(InputChip), findsOneWidget);

    await tester.enterText(find.byType(TextField), '总结这个文件');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // The bubble shows the file-name chip and the raw text only — the file
    // body rides along to the model, not the transcript.
    expect(find.text('总结这个文件'), findsWidgets);
    expect(find.text('第 1 行'), findsNothing);
    expect(find.textContaining('--- 附件'), findsNothing);
    expect(find.text('notes.md'), findsOneWidget);
    // The composer chip was consumed by the send.
    expect(find.byType(InputChip), findsNothing);
  });
}

class _FakeSpeech implements SpeechTranscriber {
  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) async {
    onResult('帮我把会议纪要整理', false);
    onResult('帮我把会议纪要整理成待办', true);
  }

  @override
  Future<void> stop() async {}
}

class _UnavailableSpeech implements SpeechTranscriber {
  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) async {}

  @override
  Future<void> stop() async {}
}
