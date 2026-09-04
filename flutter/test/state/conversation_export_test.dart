import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/conversation_export.dart';

void main() {
  test('exports user and assistant turns as Markdown', () {
    final markdown = exportConversationMarkdown(
      title: '修复登录页崩溃',
      exportedAt: DateTime(2026, 9, 4, 10, 5),
      entries: [
        UserEntry('登录页崩溃了', fileNames: ['log.txt'], images: ['data:image/png;base64,xx']),
        AssistantEntry(text: '我看看日志,可能是空指针。'),
      ],
    );

    expect(markdown, contains('# 修复登录页崩溃'));
    expect(markdown, contains('- 导出时间:2026-09-04 10:05'));
    expect(markdown, contains('**用户**'));
    expect(markdown, contains('登录页崩溃了'));
    expect(markdown, contains('- 附件文件:log.txt'));
    expect(markdown, contains('- 图片附件 × 1'));
    expect(markdown, contains('**Shelly**'));
    expect(markdown, contains('可能是空指针'));
    // Attachment bodies never enter the export.
    expect(markdown, isNot(contains('base64')));
  });

  test('exports tool runs and errors as quotes', () {
    final call = ToolCall(id: 't1', name: 'read_file', argumentsJson: '{}');
    final tool = ToolEntry(call: call)
      ..status = ToolRunStatus.succeeded
      ..durationMillis = 1234;
    final markdown = exportConversationMarkdown(
      entries: [tool, ErrorEntry('网关超时'), NoticeEntry('上下文已自动压缩')],
    );

    expect(markdown, contains('`read_file` · 成功 · 1.2s'));
    expect(markdown, contains('> 出错:网关超时'));
    expect(markdown, contains('> 上下文已自动压缩'));
  });

  test('skips the empty streaming placeholder', () {
    final markdown = exportConversationMarkdown(
      entries: [AssistantEntry(text: '', streaming: true)],
    );
    expect(markdown, isNot(contains('**Shelly**')));
  });

  test('falls back to a default title', () {
    final markdown = exportConversationMarkdown(entries: const []);
    expect(markdown, startsWith('# Shelly 对话'));
  });
}
