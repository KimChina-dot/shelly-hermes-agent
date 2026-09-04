import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/context/context_compactor.dart';
import 'package:shelly_hermes/core/gateway/context_window.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/tools/registry.dart';

AgentMessage _user(String text) => AgentMessage(role: MessageRole.user, content: text);

AgentMessage _assistant(String text) =>
    AgentMessage(role: MessageRole.assistant, content: text);

/// A long deterministic filler body (~CJK, so estimates stay predictable).
String _filler(String tag, {int chars = 400}) => '$tag${'对话内容' * (chars ~/ 4)}';

void main() {
  group('token estimation', () {
    test('counts CJK characters more aggressively than latin', () {
      final cjk = estimateMessageTokens(_user('你好世界' * 10)); // 40 CJK chars
      final latin = estimateMessageTokens(_user('a' * 40));
      expect(cjk, greaterThan(latin));
      expect(cjk, 48); // 40 CJK + 8 overhead
    });

    test('counts every attached image as a fixed chunk', () {
      final plain = estimateMessageTokens(_user('hi'));
      final withImage = estimateMessageTokens(AgentMessage(
        role: MessageRole.user,
        content: 'hi',
        images: const ['data:image/jpeg;base64,AAA'],
      ));
      expect(withImage - plain, 800);
    });
  });

  group('ContextCompactor', () {
    test('threshold check fires past the configured share of the window', () {
      final compactor = ContextCompactor(windowTokens: 1000, threshold: 0.8);
      expect(compactor.needsCompaction([_user('短消息')]), isFalse);
      expect(
        compactor
            .needsCompaction([_user('长' * 900)]), // ~908 tokens
        isTrue,
      );
    });

    test('returns the input untouched while the tail still fits', () async {
      final compactor = ContextCompactor(
        windowTokens: 100000,
        keepRecentGroups: 4,
      );
      final messages = [
        _user('任务'),
        _assistant('回复'),
      ];
      final result = await compactor.compact(messages);
      expect(result.droppedMessages, 0);
      expect(identical(result.messages, messages), isTrue);
    });

    test('folds older exchanges, keeps system + recent tail verbatim',
        () async {
      final compactor = ContextCompactor(
        windowTokens: 100000,
        keepRecentGroups: 2,
      );
      final messages = [
        const AgentMessage(role: MessageRole.system, content: '人设'),
        _user(_filler('任务1')),
        _assistant(_filler('回复1')),
        _user(_filler('任务2')),
        _assistant(_filler('回复2')),
        _user(_filler('任务3')),
        _assistant(_filler('回复3')),
        _user(_filler('任务4')),
        _assistant(_filler('回复4')),
      ];

      final result = await compactor.compact(messages);

      expect(result.droppedMessages, greaterThan(0));
      expect(result.usedModelSummary, isFalse);
      expect(result.tokensAfter, lessThan(result.tokensBefore));
      // Head system message survives verbatim.
      expect(result.messages.first.content, '人设');
      // Exactly one summary system message follows.
      final summary = result.messages
          .where((m) => m.content.startsWith('以下是此前对话的自动压缩摘要'))
          .toList();
      expect(summary, hasLength(1));
      // The original task line is preserved inside the heuristic summary.
      expect(summary.single.content, contains('任务1'));
      // The last two exchange groups come back verbatim, in order.
      final tail = result.messages.skip(2).toList();
      expect(tail.first.content, contains('任务4'));
      expect(tail.last.content, contains('回复4'));
      expect(result.messages.length, lessThan(messages.length));
    });

    test('kept tail never starts with an orphaned tool message', () async {
      final compactor = ContextCompactor(
        windowTokens: 100000,
        keepRecentGroups: 1,
      );
      final messages = [
        _user(_filler('任务1')),
        AgentMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [
            const ToolCall(id: 'c1', name: 'read_file', argumentsJson: '{}'),
          ],
        ),
        AgentMessage(role: MessageRole.tool, content: '结果1', toolCallId: 'c1'),
        _user(_filler('任务2')),
        AgentMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [
            const ToolCall(id: 'c2', name: 'read_file', argumentsJson: '{}'),
          ],
        ),
        AgentMessage(role: MessageRole.tool, content: '结果2', toolCallId: 'c2'),
        _user('继续'),
      ];

      final result = await compactor.compact(messages);

      expect(result.messages.first.role, MessageRole.system);
      // The only kept group is the final user turn; no tool message leads.
      expect(result.messages.last.role, MessageRole.user);
      expect(result.messages.last.content, '继续');
      expect(
        result.messages
            .where((m) => m.role == MessageRole.tool)
            .toList(),
        isEmpty,
      );
    });

    test('uses the model summarizer when it succeeds', () async {
      final compactor = ContextCompactor(
        windowTokens: 100000,
        keepRecentGroups: 1,
        summarizer: (transcript) async => '模型摘要:$transcript',
      );
      final messages = [
        _user(_filler('任务1')),
        _assistant(_filler('回复1')),
        _user(_filler('任务2')),
        _assistant(_filler('回复2')),
        _user('最后一条'),
      ];

      final result = await compactor.compact(messages);

      expect(result.usedModelSummary, isTrue);
      expect(
        result.messages
            .where((m) => m.content.contains('模型摘要:'))
            .toList(),
        hasLength(1),
      );
    });

    test('falls back to the heuristic when the summarizer fails', () async {
      final compactor = ContextCompactor(
        windowTokens: 100000,
        keepRecentGroups: 1,
        summarizer: (transcript) async => throw StateError('gateway down'),
      );
      final messages = [
        _user(_filler('任务1')),
        _assistant(_filler('回复1')),
        _user(_filler('任务2')),
        _assistant(_filler('回复2')),
        _user('最后一条'),
      ];

      final result = await compactor.compact(messages);

      expect(result.usedModelSummary, isFalse);
      expect(result.messages.where((m) => m.content.contains('任务1')), hasLength(1));
    });
  });

  group('AgentCore integration', () {
    test('compacts before a model round when the window is exceeded',
        () async {
      final model = _ScriptedModel([
        const ModelReply(content: '完成'),
      ]);
      final compactor = ContextCompactor(
        windowTokens: 200, // tiny window: the filler transcript overflows
        keepRecentGroups: 1,
        summarizer: (transcript) async => '压缩后的要点',
      );
      final core = AgentCore(
        model: model,
        tools: _NoopTools(),
        approvals: _NoopApprovals(),
        checkpoints: _NoopCheckpoints(),
        contextCompactor: compactor,
      );
      final original = <AgentMessage>[
        _user(_filler('很长很长的任务', chars: 800)),
        _assistant(_filler('很长的回复', chars: 800)),
        _user('继续收尾'),
      ];

      final result = await core.run(original, CancelFlag(),
          resumeFrom: AgentCheckpoint(
            messages: original,
            round: 0,
            consumedTokens: 0,
            toolCalls: 0,
          ));

      expect(result, isA<AgentCompleted>());
      // The model saw the compacted transcript, not the original bulk.
      expect(model.seenMessages, hasLength(1));
      expect(
        model.seenMessages.single.any((m) => m.content.contains('压缩后的要点')),
        isTrue,
      );
      expect(
        model.seenMessages.single.any((m) => m.content.contains('很长的任务')),
        isFalse,
      );
    });

    test('context window presets and manual overrides', () {
      expect(contextWindowForModel('deepseek-chat'), 65536);
      expect(contextWindowForModel('claude-3-5-sonnet'), 200000);
      expect(contextWindowForModel('gpt-4o-mini'), 128000);
      expect(contextWindowForModel('totally-unknown-model'), 32768);
    });
  });
}

class _NoopTools implements AgentToolRegistry {
  @override
  List<ToolSpec> get specs => const [];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => const [];

  @override
  Future<String> execute(ToolCall call) async => '';
}

class _ScriptedModel implements StreamingModelGateway {
  _ScriptedModel(this.replies);

  final List<ModelReply> replies;
  List<List<AgentMessage>> seenMessages = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seenMessages.add(List.of(messages));
    return replies.removeAt(0);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

class _NoopApprovals implements ApprovalGateway {
  @override
  Future<ApprovalDecision> request(ToolCall call) async => ApprovalDecision.approve;
}

class _NoopCheckpoints implements CheckpointStore {
  final List<AgentCheckpoint> saved = [];

  @override
  Future<void> save(AgentCheckpoint checkpoint) async => saved.add(checkpoint);
}
