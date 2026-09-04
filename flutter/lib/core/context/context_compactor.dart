// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../models.dart';

/// One token estimate unit per CJK character (conservative; real tokenizers
/// sit around 0.6–1.0) and one per four latin characters, plus a small
/// per-message and per-image overhead.
const _cjkTokenCost = 1.0;
const _latinCharsPerToken = 4.0;
const _messageOverheadTokens = 8;
const _imageTokens = 800;

/// Rough, deterministic token estimate for a message list. Deliberately
/// biased high: compacting early costs far less than an overflowing request.
int estimateMessageTokens(AgentMessage message) {
  var tokens = _messageOverheadTokens + message.images.length * _imageTokens;
  var cjk = 0;
  for (final unit in message.content.codeUnits) {
    if (unit > 0x2E80) cjk += 1;
  }
  final latin = message.content.length - cjk;
  return tokens + (cjk * _cjkTokenCost + latin / _latinCharsPerToken).ceil();
}

int estimateTokens(List<AgentMessage> messages) =>
    messages.fold(0, (sum, m) => sum + estimateMessageTokens(m));

/// Keeps a running conversation inside the model's context window by folding
/// older exchanges into a summary before each model round.
///
/// Compaction operates on exchange groups — one user/assistant message plus
/// any tool messages it produced — so a kept tail can never start with an
/// orphaned tool message that lost its assistant tool_calls pair.
class ContextCompactor {
  ContextCompactor({
    required this.windowTokens,
    this.threshold = 0.8,
    this.keepRecentGroups = 4,
    this.summarizer,
  })  : assert(windowTokens > 0),
        assert(threshold > 0 && threshold <= 1),
        assert(keepRecentGroups >= 1);

  final int windowTokens;

  /// Compaction starts once the estimate crosses this share of the window.
  final double threshold;

  /// Exchange groups at the tail that are always kept verbatim.
  final int keepRecentGroups;

  /// Optional model-backed summarizer. Failures degrade to the heuristic
  /// placeholder; compaction itself must never break the agent loop.
  final Future<String> Function(String transcript)? summarizer;

  bool needsCompaction(List<AgentMessage> messages) =>
      estimateTokens(messages) > windowTokens * threshold;

  /// Folds older exchanges into a summary and reports what happened. When
  /// nothing needs folding the original list comes back untouched.
  Future<CompactionResult> compact(List<AgentMessage> messages) async {
    final tokensBefore = estimateTokens(messages);
    final groups = _exchangeGroups(messages);
    if (groups.exchangeCount <= keepRecentGroups) {
      return CompactionResult.unchanged(messages, tokensBefore);
    }

    final kept = <_Group>[];
    var keptGroups = 0;
    var index = groups.list.length - 1;
    while (index >= 0 && keptGroups < keepRecentGroups) {
      final group = groups.list[index];
      if (group.isSystem) break;
      kept.insert(0, group);
      keptGroups += 1;
      index -= 1;
    }
    final dropped = groups.list.sublist(0, index + 1).where((g) => !g.isSystem).toList();
    if (dropped.isEmpty) {
      return CompactionResult.unchanged(messages, tokensBefore);
    }

    final firstTask = _firstUserLine(dropped);
    final droppedCount = dropped.fold(0, (n, g) => n + g.messages.length);
    final transcript = _transcript(dropped);
    String? summary;
    var usedModelSummary = false;
    final summarizer = this.summarizer;
    if (summarizer != null) {
      try {
        final text = (await summarizer(transcript)).trim();
        if (text.isNotEmpty) {
          summary = text;
          usedModelSummary = true;
        }
      } catch (_) {
        // Degrade to the heuristic placeholder below.
      }
    }
    summary ??= '（此前 $droppedCount 条消息已折叠:任务为「$firstTask」。'
        '具体早期对话与工具结果不再保留,请基于当前上下文继续。）';

    final compacted = [
      ...groups.list.where((g) => g.isSystem).expand((g) => g.messages),
      AgentMessage(
        role: MessageRole.system,
        content: '以下是此前对话的自动压缩摘要:\n$summary',
      ),
      ...kept.expand((g) => g.messages),
    ];
    return CompactionResult(
      messages: compacted,
      droppedMessages: droppedCount,
      tokensBefore: tokensBefore,
      tokensAfter: estimateTokens(compacted),
      usedModelSummary: usedModelSummary,
    );
  }

  String _firstUserLine(List<_Group> dropped) {
    for (final group in dropped) {
      for (final message in group.messages) {
        if (message.role == MessageRole.user && message.content.trim().isNotEmpty) {
          final line = message.content.trim().replaceAll('\n', ' ');
          return line.length > 60 ? '${line.substring(0, 60)}…' : line;
        }
      }
    }
    return '未记录';
  }

  String _transcript(List<_Group> dropped) {
    final buffer = StringBuffer();
    for (final group in dropped) {
      for (final message in group.messages) {
        var content = message.content;
        if (content.length > 2000) content = '${content.substring(0, 2000)}…';
        final tag = switch (message.role) {
          MessageRole.system => 'system',
          MessageRole.user => 'user',
          MessageRole.assistant => 'assistant',
          MessageRole.tool => 'tool(${message.toolCallId ?? '?'})',
        };
        buffer.writeln('[$tag] $content');
      }
    }
    return buffer.toString();
  }
}

/// Outcome of one [ContextCompactor.compact] call, surfaced as telemetry so
/// the UI can tell the user their context was folded.
class CompactionResult {
  const CompactionResult({
    required this.messages,
    required this.droppedMessages,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.usedModelSummary,
  });

  factory CompactionResult.unchanged(List<AgentMessage> messages, int tokens) =>
      CompactionResult(
        messages: messages,
        droppedMessages: 0,
        tokensBefore: tokens,
        tokensAfter: tokens,
        usedModelSummary: false,
      );

  final List<AgentMessage> messages;
  final int droppedMessages;
  final int tokensBefore;
  final int tokensAfter;

  /// False when the model-based summarizer failed and the heuristic
  /// placeholder was used, or when nothing was folded at all.
  final bool usedModelSummary;
}

class _Groups {
  _Groups(this.list, this.exchangeCount);

  final List<_Group> list;
  final int exchangeCount;
}

class _Group {
  _Group.system(this.messages) : isSystem = true;
  _Group.exchange(this.messages) : isSystem = false;

  final List<AgentMessage> messages;
  final bool isSystem;
}

/// Splits the transcript into system groups (kept verbatim by compaction)
/// and exchange groups (one trigger message + its tool results).
_Groups _exchangeGroups(List<AgentMessage> messages) {
  final groups = <_Group>[];
  var exchangeCount = 0;
  var i = 0;
  while (i < messages.length) {
    final message = messages[i];
    if (message.role == MessageRole.system) {
      groups.add(_Group.system([message]));
      i += 1;
      continue;
    }
    final group = <AgentMessage>[message];
    i += 1;
    // Absorb the tool results produced by this assistant turn so a kept
    // group never begins with an orphaned tool message.
    while (i < messages.length && messages[i].role == MessageRole.tool) {
      group.add(messages[i]);
      i += 1;
    }
    groups.add(_Group.exchange(group));
    exchangeCount += 1;
  }
  return _Groups(groups, exchangeCount);
}
