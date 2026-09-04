import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/platform/conversation_images.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resume rebuilds tool cards from checkpoint messages', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final store = SettingsStore(await SharedPreferences.getInstance());
    await store.saveCheckpoint(
      'conv-1',
      AgentCheckpoint(
        round: 2,
        consumedTokens: 0,
        toolCalls: 1,
        messages: [
          const AgentMessage(role: MessageRole.user, content: '演示补丁'),
          const AgentMessage(role: MessageRole.assistant, content: '', toolCalls: [
            ToolCall(
              id: 'call-1',
              name: 'write_file',
              argumentsJson: '{"path":"demo/a.md","content":"hi"}',
            ),
          ]),
          const AgentMessage(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'ok',
          ),
          const AgentMessage(role: MessageRole.assistant, content: '写好了'),
        ],
      ),
    );

    final controller = container.read(chatSessionProvider.notifier);
    controller.attach(store);
    await controller.resume('conv-1');

    final entries = container.read(chatSessionProvider).entries;
    final toolEntry = entries.whereType<ToolEntry>().toList();
    expect(toolEntry, hasLength(1));
    expect(toolEntry.single.call.id, 'call-1');
    expect(toolEntry.single.status, ToolRunStatus.succeeded);
    expect(toolEntry.single.result, 'ok');
    expect(entries.whereType<UserEntry>().single.text, '演示补丁');
    expect(entries.whereType<AssistantEntry>().single.text, '写好了');
  });

  test('sent images persist to disk; checkpoints hold paths, not base64',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tempDir =
        await Directory.systemTemp.createTemp('shelly-session-img');
    addTearDown(() => tempDir.delete(recursive: true));

    final container = ProviderContainer(overrides: [
      conversationImageStoreProvider
          .overrideWith((ref) async => ConversationImageStore(tempDir)),
    ]);
    addTearDown(container.dispose);

    final store = SettingsStore(await SharedPreferences.getInstance());
    final controller = container.read(chatSessionProvider.notifier);
    controller.attach(store);

    // Real 1x1 PNG so the demo run's checkpoint round-trip is realistic.
    const pngDataUrl =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    await controller.send('看这张图', images: [pngDataUrl]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final conversationId = container.read(chatSessionProvider).conversationId;
    // Wait for the demo task to finish persisting its checkpoint.
    for (var i = 0; i < 100; i += 1) {
      if (store.loadCheckpoint(conversationId!) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final checkpoint = store.loadCheckpoint(conversationId!);
    expect(checkpoint, isNotNull);
    final imageRef = checkpoint!.messages
        .expand((m) => m.images)
        .single;
    expect(imageRef.startsWith('data:'), isFalse);
    expect(File(imageRef).existsSync(), isTrue);
    expect(File(imageRef).lengthSync(),
        base64Decode(pngDataUrl.split(',').last).length);
    // In-memory transcript keeps the data URL for immediate display.
    final entry =
        container.read(chatSessionProvider).entries.whereType<UserEntry>().first;
    expect(entry.images.single, pngDataUrl);
  });
}

