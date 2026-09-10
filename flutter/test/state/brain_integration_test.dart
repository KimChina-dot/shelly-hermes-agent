/// PHASE 8 brain preflight integration tests.
///
/// Covers the end-to-end wiring through the chat session's task runner via
/// the `chatGatewayOverrideProvider` pattern: a multi-step send must seed
/// the Brain plan into the opening 「当前计划」 recitation block, a
/// quick-answer send must bypass the planner with zero extra calls, every
/// Brain prefill must land in the same consumedTokens budget the agent
/// rounds charge (read back through the persisted checkpoint), and a broken
/// classify call must degrade to "no plan" without failing the task. A
/// focused [AgentCore] group pins the budget seam itself: the seed joins
/// the one maxTokens budget, and a resume's checkpoint value wins over it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub that replays canned replies and records every request
/// (same pattern as mission_coordinator_test.dart). When the script is
/// exhausted it throws, which fails the task through the real engine
/// error path.
class _ScriptedGateway implements StreamingModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    if (replies.isNotEmpty) return replies.removeAt(0);
    throw StateError('script exhausted');
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = await complete(messages);
    if (reply.content.isNotEmpty) onDelta(reply.content);
    return reply;
  }

  bool get anySystemMessageHasPlan => seen.any(
        (round) => round.any(
          (message) =>
              message.role == MessageRole.system &&
              message.content.contains('「当前计划」'),
        ),
      );
}

/// Gateway whose first call (the Brain classify prefill) throws; later
/// calls answer normally — the fail-open shape of a broken classifier.
class _FirstCallThrowsGateway implements StreamingModelGateway {
  _FirstCallThrowsGateway(this.mainReply);

  final ModelReply mainReply;
  final List<List<AgentMessage>> seen = [];
  var _calls = 0;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    _calls += 1;
    if (_calls == 1) throw StateError('classify down');
    return mainReply;
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = await complete(messages);
    if (reply.content.isNotEmpty) onDelta(reply.content);
    return reply;
  }

  bool get anySystemMessageHasPlan => seen.any(
        (round) => round.any(
          (message) =>
              message.role == MessageRole.system &&
              message.content.contains('「当前计划」'),
        ),
      );
}

/// Waits until the chat task settles (idle), failing after ~10s.
Future<void> _waitForIdle(ProviderContainer container) async {
  for (var i = 0; i < 500; i += 1) {
    if (!container.read(chatSessionProvider).isBusy) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('chat task did not return to idle');
}

/// The final checkpoint of the last conversation, read back through the
/// mock prefs the same way the app persists it.
Future<AgentCheckpoint> _finalCheckpoint() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getKeys().firstWhere(
        (k) => k.startsWith('shelly.checkpoint.'),
      );
  return AgentCheckpoint.decode(prefs.getString(key)!);
}

ProviderContainer _container(StreamingModelGateway gateway) {
  final container = ProviderContainer(overrides: [
    chatGatewayOverrideProvider.overrideWith((ref) => gateway),
  ]);
  return container;
}

Future<void> _send(ProviderContainer container, String text) async {
  final store = SettingsStore(await SharedPreferences.getInstance());
  final controller = container.read(chatSessionProvider.notifier);
  controller.attach(store);
  await controller.send(text);
  await _waitForIdle(container);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('brain preflight ↔ chat session (end-to-end)', () {
    test('a multi-step send seeds the plan into the opening system prompt',
        () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([
        // Brain classify → multiStep.
        ModelReply(content: 'multiStep', inputTokens: 30, outputTokens: 10),
        // Brain plan → three numbered steps.
        ModelReply(
          content: '1. 打开文件夹\n2. 复制文件\n3. 汇报结果',
          inputTokens: 50,
          outputTokens: 20,
        ),
        // The agent round proper.
        ModelReply(content: '第一答', inputTokens: 100, outputTokens: 40),
      ]);
      final container = _container(gateway);
      addTearDown(container.dispose);

      await _send(container, '请帮我分三步整理桌面文件');

      // classify + plan + exactly one agent round.
      expect(gateway.seen, hasLength(3));
      // The plan opens the task as the 「当前计划」 recitation paragraph.
      expect(gateway.anySystemMessageHasPlan, isTrue);
      final systemMessage = gateway.seen[2].first;
      expect(systemMessage.role, MessageRole.system);
      expect(systemMessage.content, contains('「当前计划」'));
      expect(systemMessage.content, contains('1. 打开文件夹'));
      expect(systemMessage.content, contains('2. 复制文件'));
      expect(systemMessage.content, contains('3. 汇报结果'));
    });

    test('a quick-answer send bypasses the planner with zero extra calls',
        () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([
        ModelReply(content: 'quickAnswer', inputTokens: 30, outputTokens: 10),
        ModelReply(content: '好的', inputTokens: 100, outputTokens: 40),
      ]);
      final container = _container(gateway);
      addTearDown(container.dispose);

      await _send(container, '今天天气怎么样');

      // classify + one agent round; the planner call never happens.
      expect(gateway.seen, hasLength(2));
      expect(gateway.anySystemMessageHasPlan, isFalse);
    });

    test('brain prefill tokens land in the same consumedTokens budget',
        () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep', inputTokens: 30, outputTokens: 10),
        ModelReply(content: '1. 打开文件夹\n2. 复制文件', inputTokens: 50, outputTokens: 20),
        ModelReply(content: '第一答', inputTokens: 100, outputTokens: 40),
      ]);
      final container = _container(gateway);
      addTearDown(container.dispose);

      await _send(container, '请帮我分两步整理桌面文件');

      // 40 (brain classify) + 70 (brain plan) + 140 (agent round).
      final checkpoint = await _finalCheckpoint();
      expect(checkpoint.consumedTokens, 250);
    });

    test('a broken classify call degrades to no plan without failing the '
        'task', () async {
      SharedPreferences.setMockInitialValues({});
      final gateway = _FirstCallThrowsGateway(
        const ModelReply(content: '直接回答', inputTokens: 100, outputTokens: 40),
      );
      final container = _container(gateway);
      addTearDown(container.dispose);

      await _send(container, '触发分类故障的消息');

      // The failed classify plus the one agent round — task completed.
      expect(gateway.seen, hasLength(2));
      expect(gateway.anySystemMessageHasPlan, isFalse);
    });
  });

  group('AgentCore initialConsumedTokens seam', () {
    test('the seed joins the one maxTokens budget and stops the run',
        () async {
      // 100 seeded + 70000 from the first reply > 64000 budget.
      final core = AgentCore(
        model: _SingleReplyGateway(
          const ModelReply(content: 'x', inputTokens: 70000),
        ),
        tools: _NoTools(),
        approvals: _ApproveAll(),
        checkpoints: _MemoryCheckpoints(),
        limits: const AgentLimits(maxRounds: 4, maxTokens: 64000),
        initialConsumedTokens: 100,
      );
      final result = await core.run(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
        CancelFlag(),
      );
      expect(result, isA<AgentStopped>());
      expect((result as AgentStopped).reason, 'token_budget_exceeded');
      expect(result.checkpoint.consumedTokens, 70100);
    });

    test('a resume checkpoint wins over the seed', () async {
      final core = AgentCore(
        model: _SingleReplyGateway(
          const ModelReply(content: 'x', inputTokens: 5),
        ),
        tools: _NoTools(),
        approvals: _ApproveAll(),
        checkpoints: _MemoryCheckpoints(),
        limits: const AgentLimits(maxRounds: 4, maxTokens: 64000),
        initialConsumedTokens: 999,
      );
      final resumedFrom = AgentCheckpoint(
        messages: const [AgentMessage(role: MessageRole.user, content: '旧')],
        round: 2,
        consumedTokens: 10,
        toolCalls: 0,
      );
      final result = await core.run(
        const [AgentMessage(role: MessageRole.user, content: '新')],
        CancelFlag(),
        resumeFrom: resumedFrom,
      );
      // 10 from the checkpoint, not 999 from the seed; plus the round's 5.
      expect((result as AgentCompleted).checkpoint.consumedTokens, 15);
    });
  });
}

/// Gateway with one fixed reply, for the focused [AgentCore] seam tests.
class _SingleReplyGateway implements ModelGateway {
  _SingleReplyGateway(this.reply);

  final ModelReply reply;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async => reply;
}

class _NoTools implements ToolExecutor {
  @override
  Future<String> execute(ToolCall call) async => 'ok';
}

class _ApproveAll implements ApprovalGateway {
  @override
  Future<ApprovalDecision> request(ToolCall call) async =>
      ApprovalDecision.approve;
}

class _MemoryCheckpoints implements CheckpointStore {
  @override
  Future<void> save(AgentCheckpoint checkpoint) async {}
}
