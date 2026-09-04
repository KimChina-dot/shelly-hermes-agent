import 'chat_session.dart';

/// Renders the visible transcript into a portable Markdown document for the
/// system share sheet. Attachments appear as references only — image bytes
/// and text-file bodies stay out of the export.
String exportConversationMarkdown({
  String? title,
  required List<ChatEntry> entries,
  DateTime? exportedAt,
}) {
  final buffer = StringBuffer();
  buffer.writeln('# ${title ?? 'Shelly 对话'}');
  buffer.writeln();
  final when = exportedAt ?? DateTime.now();
  buffer.writeln('- 导出时间:${_formatTimestamp(when)}');
  buffer.writeln();

  for (final entry in entries) {
    buffer.writeln('---');
    buffer.writeln();
    switch (entry) {
      case final UserEntry user:
        buffer.writeln('**用户**');
        buffer.writeln();
        if (user.text.isNotEmpty) buffer.writeln(user.text);
        for (final name in user.fileNames) {
          buffer.writeln('- 附件文件:$name');
        }
        if (user.images.isNotEmpty) {
          buffer.writeln('- 图片附件 × ${user.images.length}');
        }
      case final AssistantEntry assistant:
        if (assistant.text.isEmpty && assistant.streaming) continue;
        buffer.writeln('**Shelly**');
        buffer.writeln();
        if (assistant.text.isNotEmpty) buffer.writeln(assistant.text);
      case final ToolEntry tool:
        final status = switch (tool.status) {
          ToolRunStatus.running => '执行中',
          ToolRunStatus.succeeded => '成功',
          ToolRunStatus.failed => '失败',
        };
        final seconds = (tool.durationMillis / 1000).toStringAsFixed(1);
        buffer.writeln('> 工具调用 `${tool.call.name}` · $status · ${seconds}s');
      case final ErrorEntry error:
        buffer.writeln('> 出错:${error.text}');
      case final NoticeEntry notice:
        buffer.writeln('> ${notice.text}');
    }
    buffer.writeln();
  }
  return buffer.toString().trimRight();
}

String _formatTimestamp(DateTime time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${pad(time.month)}-${pad(time.day)} '
      '${pad(time.hour)}:${pad(time.minute)}';
}
