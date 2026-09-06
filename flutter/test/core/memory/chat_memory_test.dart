import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Scripted gateway driving full chat rounds (the flutter_test binding
/// blocks real sockets, so the production OpenAI-compatible gateway cannot
/// be reached; same fake-gateway pattern as the tests in test/state).
/// Streaming delivers the content as deltas, exactly like the real wire.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    return replies.removeAt(0);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = await complete(messages);
    for (var i = 0; i < reply.content.length; i += 2) {
      final end = (i + 2).clamp(0, reply.content.length);
      onDelta(reply.content.substring(i, end));
    }
    return reply;
  }
}

ModelReply _reply(String text) => ModelReply(content: text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a completed chat round stores a memory fact; the next round ships '
      'it in the system prompt', () async {
    SharedPreferences.setMockInitialValues({});

    // Per round: the chat reply, then the extractor's JSON array.
    final gateway = _ScriptedGateway([
      _reply('好的,已记住。'),
      _reply('["用户偏好简洁的中文回复"]'),
      _reply('好的,已记住。'),
      _reply('["用户偏好简洁的中文回复"]'),
    ]);

    final store = SettingsStore(await SharedPreferences.getInstance());
    // A complete config turns the extractor on; the scripted gateway
    // replaces the real endpoint for the rounds themselves.
    await store.saveModelConfig(const ModelConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'test-model',
      contextWindow: 100000,
    ));

    final container = ProviderContainer(overrides: [
      chatGatewayOverrideProvider.overrideWithValue(gateway),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(chatSessionProvider.notifier);
    controller.attach(store);

    // Round 1: the completed round feeds the extractor...
    await controller.send('请记住我喜欢简洁的回复');
    await _until(() => container.read(chatSessionProvider).phase ==
        SessionPhase.idle);
    expect(container.read(chatSessionProvider).phase, SessionPhase.idle);
    final reply = container.read(chatSessionProvider).entries
        .whereType<AssistantEntry>()
        .map((e) => e.text)
        .join();
    expect(reply, contains('好的,已记住。'));

    // ...with the latest user + assistant pair as its input.
    await _until(() => gateway.seen.length >= 2);
    final extractionInput = gateway.seen[1];
    expect(extractionInput.first.role, MessageRole.system);
    expect(
      extractionInput.last.content,
      allOf(
        contains('请记住我喜欢简洁的回复'),
        contains('好的,已记住。'),
      ),
    );

    // ...and the fact lands in the store, tagged with the conversation.
    final memory = MemoryStore(await SharedPreferences.getInstance());
    final conversationId = container.read(chatSessionProvider).conversationId;
    await _until(() => memory.loadFacts().isNotEmpty);
    final facts = memory.loadFacts();
    expect(facts, hasLength(1));
    expect(facts.single.text, '用户偏好简洁的中文回复');
    expect(facts.single.sourceConversationId, conversationId);

    // Round 2: the stored memory rides along in the system prompt.
    await controller.send('再聊两句');
    await _until(() =>
        container.read(chatSessionProvider).phase == SessionPhase.idle &&
        gateway.seen.length >= 3);
    final round2Messages = gateway.seen[2];
    expect(
      round2Messages.any((m) =>
          m.role == MessageRole.system &&
          m.content.contains('「长期记忆」') &&
          m.content.contains('用户偏好简洁的中文回复')),
      isTrue,
    );

    // The second round re-extracts the same fact; dedupe keeps the store at 1.
    await _until(() => gateway.seen.length >= 4);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(memory.loadFacts().length, 1);
    expect(memory.loadFacts().single.text, '用户偏好简洁的中文回复');
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500; i += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition not met within timeout');
}
