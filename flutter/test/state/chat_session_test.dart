import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/models.dart';
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
}
