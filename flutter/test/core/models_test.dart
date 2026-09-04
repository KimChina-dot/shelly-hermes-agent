import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/diff_approval.dart';
import 'package:shelly_hermes/core/models.dart';

void main() {
  group('AgentCheckpoint codec', () {
    test('round-trips through JSON', () {
      const call = ToolCall(id: 't1', name: 'write_file', argumentsJson: '{"path":"a"}');
      final checkpoint = AgentCheckpoint(
        messages: const [
          AgentMessage(role: MessageRole.user, content: 'hi'),
          AgentMessage(role: MessageRole.assistant, content: '', toolCalls: [call]),
          AgentMessage(role: MessageRole.tool, content: 'ok', toolCallId: 't1'),
        ],
        round: 3,
        consumedTokens: 1200,
        toolCalls: 4,
        pendingToolCalls: [
          PendingToolCall(call: call, stage: ToolExecutionStage.awaitingApproval),
        ],
      );

      final restored = AgentCheckpoint.decode(checkpoint.encode());

      expect(restored, checkpoint);
      expect(restored.pendingToolCalls.single.stage, ToolExecutionStage.awaitingApproval);
    });

    test('rejects unknown versions', () {
      const raw = '{"version":99,"messages":[],"round":0,"consumedTokens":0,"toolCalls":0}';

      expect(() => AgentCheckpoint.decode(raw), throwsFormatException);
    });

    test('AgentMessage round-trips attached images through JSON', () {
      const message = AgentMessage(
        role: MessageRole.user,
        content: '看这张图',
        images: ['data:image/jpeg;base64,QUJD'],
      );

      final restored = AgentMessage.fromJson(message.toJson());

      expect(restored, message);
      expect(restored.images, message.images);
    });

    test('AgentMessage round-trips text-file attachments', () {
      const message = AgentMessage(
        role: MessageRole.user,
        content: '看下这个配置',
        textFiles: [TextFileAttachment(name: 'app.json', content: '{"a":1}')],
      );

      final restored = AgentMessage.fromJson(message.toJson());

      expect(restored, message);
      expect(restored.textFiles.single.name, 'app.json');
      expect(
        composeMessageContent('看下这个配置', message.textFiles),
        contains('--- 附件:app.json ---'),
      );
    });

    test('AgentMessage decodes legacy JSON without images', () {
      final restored = AgentMessage.fromJson({
        'role': 'user',
        'content': '纯文本历史消息',
      });

      expect(restored.images, isEmpty);
    });
  });

  test('DiffApprovalState tracks per-hunk decisions', () {
    const hunkA = DiffHunk(id: 'h1', filePath: 'a.dart', header: '@@ -1 +1 @@', lines: ['-a', '+b']);
    const hunkB = DiffHunk(id: 'h2', filePath: 'a.dart', header: '@@ -5 +5 @@', lines: ['-c', '+d']);
    var state = const DiffApprovalState();

    expect(state.isComplete([hunkA, hunkB]), isFalse);
    expect(state.decisionFor(hunkA), HunkDecision.pending);

    state = state.decide('h1', HunkDecision.approved);
    expect(state.isComplete([hunkA, hunkB]), isFalse);

    state = state.decide('h2', HunkDecision.rejected);
    expect(state.isComplete([hunkA, hunkB]), isTrue);
    expect(state.approved([hunkA, hunkB]), [hunkA]);
    expect(state.renderApproved([hunkA, hunkB]), hunkA.render());
  });

  test('DiffHunk.render produces a unified-diff style block', () {
    const hunk = DiffHunk(id: 'h1', filePath: 'src/x.dart', header: '@@ -1 +1 @@', lines: ['-old', '+new']);

    final rendered = hunk.render();

    expect(rendered, '--- src/x.dart\n+++ src/x.dart\n@@ -1 +1 @@\n-old\n+new\n');
  });
}
