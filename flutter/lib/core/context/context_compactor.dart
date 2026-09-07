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

/// Well-known file extensions that mark a whitespace-delimited token as a
/// workspace file path. Kept deliberately conservative (source, doc and
/// config extensions only) so plain words, version numbers or email
/// domains never match.
const _pathExtensions = <String>{
  'adoc', 'astro', 'bash', 'bat', 'cc', 'cfg', 'clj', 'cljs', 'cjs', 'cmd',
  'conf', 'cpp', 'cs', 'css', 'csv', 'cxx', 'dart', 'erl', 'ex', 'exs',
  'fish', 'fs', 'fsx', 'go', 'gradle', 'gql', 'graphql', 'groovy', 'h', 'hh',
  'hpp', 'hs', 'htm', 'html', 'ini', 'ipynb', 'java', 'jl', 'js', 'json',
  'json5', 'jsonc', 'jsx', 'kt', 'kts', 'less', 'lock', 'lua', 'md',
  'markdown', 'mk', 'mjs', 'php', 'pl', 'properties', 'proto', 'ps1', 'py',
  'pyi', 'rb', 'rst', 'rs', 'sass', 'scala', 'scss', 'sh', 'sql', 'svg',
  'svelte', 'swift', 'tex', 'toml', 'ts', 'tsx', 'txt', 'vue', 'xml', 'yaml',
  'yml', 'zsh',
};

/// Alternation source for [_pathPattern]; extensions are plain word chars.
final _pathExtensionPattern = _pathExtensions.join('|');

/// Relative workspace paths with a known extension (`lib/main.dart`,
/// `docs/a.md`, `README.md`). The lookbehind keeps the match from starting
/// inside a longer token or inside an URL body.
final _pathPattern = RegExp(
  r'(?<![\w./\\:\-])'
  r'(?:[\w\-.]+[/\\])*'
  r'[\w\-.]+'
  r'\.(?:'
  '$_pathExtensionPattern'
  r')\b',
  caseSensitive: false,
);

/// http/https URLs. CJK text and common prose punctuation terminate the
/// match so copy around a URL never gets swallowed.
final _urlPattern = RegExp(
  r'https?://[^\s<>"`(),;、。…\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+',
  caseSensitive: false,
);

/// Trailing prose punctuation stripped from URL matches.
const _urlTrailingJunk = '.,;:!?\'")]}》」』、。…';

/// Upper bound on pointers carried through one compaction.
const _maxPointers = 10;

/// One-line instruction appended to the summarizer prompt so model-backed
/// summaries keep restorable pointers instead of inventing content.
const _summarizerPointerInstruction = '保留可还原指针(文件路径/URL),不要编造';

/// Strips trailing prose punctuation from a URL match.
String _trimTrailingJunk(String url) {
  while (url.isNotEmpty) {
    final last = url.substring(url.length - 1);
    if (!_urlTrailingJunk.contains(last)) break;
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Extracts restorable pointers from [text]: tokens that look like relative
/// workspace file paths with a known extension (e.g. `lib/main.dart`,
/// `docs/a.md`, `README.md`) plus http/https URLs. Results keep order of
/// first appearance, are deduplicated and capped at [_maxPointers]. Pure:
/// deterministic and free of side effects.
List<String> extractPointers(String text) {
  final found = <int, String>{};
  for (final match in _pathPattern.allMatches(text)) {
    found.putIfAbsent(match.start, () => match.group(0)!);
  }
  for (final match in _urlPattern.allMatches(text)) {
    final url = _trimTrailingJunk(match.group(0)!);
    if (url.isNotEmpty) found.putIfAbsent(match.start, () => url);
  }
  final starts = found.keys.toList()..sort();
  final pointers = <String>[];
  for (final start in starts) {
    final value = found[start]!;
    if (!pointers.contains(value)) pointers.add(value);
    if (pointers.length >= _maxPointers) break;
  }
  return pointers;
}

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
    // Restorable pointers come from the full dropped content (the transcript
    // is truncated per message, which could cut a URL in half).
    final droppedPointers =
        extractPointers(dropped.expand((g) => g.messages.map((m) => m.content)).join('\n'));
    String? summary;
    var usedModelSummary = false;
    final summarizer = this.summarizer;
    if (summarizer != null) {
      try {
        final text =
            (await summarizer('$transcript\n$_summarizerPointerInstruction')).trim();
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
    // Every compression must be reversible: if the dropped content carried
    // file paths or URLs, keep them so the agent can re-read the original.
    if (droppedPointers.isNotEmpty) {
      summary = '$summary\n「可还原指针」 ${droppedPointers.join(', ')}';
    }

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
