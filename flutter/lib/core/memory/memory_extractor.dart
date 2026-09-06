// The gateway is injected under a public constructor name while the field
// stays private; the initializing-formal rewrite would rename call sites.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import '../agent_core.dart';
import '../models.dart';

/// Extracts durable user facts from one finished chat round (PHASE 41).
/// The gateway is the same OpenAI-compatible type the summarizers use
/// (auxiliary model when enabled, otherwise the main one); tests inject a
/// scripted [ModelGateway].
///
/// Extraction is strictly best-effort: every failure mode — gateway errors,
/// malformed or prose-wrapped output, empty replies — resolves to an empty
/// list and never throws.
class MemoryExtractor {
  MemoryExtractor({required ModelGateway gateway}) : _gateway = gateway;

  final ModelGateway _gateway;

  /// The prompt asks for at most this many facts per round.
  static const int maxFactsPerRound = 3;

  /// Facts longer than this are not "concise" and are dropped.
  static const int maxFactChars = 300;

  /// Input caps keep a huge transcript round from ballooning the call.
  static const int maxInputChars = 4000;

  static const _systemPrompt =
      '你是长期记忆提取器。从下面一轮用户与助手的对话中,提取 0 到 3 条关于用户的'
      '持久事实(稳定偏好、个人背景等),不要提取一次性任务细节。'
      '只输出一个 JSON 字符串数组,例如 ["用户偏好简洁的中文回复","用户在上海工作"];'
      '没有可提取的事实时输出 []。不要输出解释、注释或代码块以外的内容。';

  /// Asks the model for facts about the latest user + assistant pair.
  /// Returns 0-[maxFactsPerRound] concise strings; never throws.
  Future<List<String>> extract({
    required String userText,
    required String assistantText,
  }) async {
    if (userText.trim().isEmpty || assistantText.trim().isEmpty) {
      return const [];
    }
    try {
      final reply = await _gateway.complete([
        const AgentMessage(role: MessageRole.system, content: _systemPrompt),
        AgentMessage(
          role: MessageRole.user,
          content: '用户:${_clip(userText)}\n\n助手:${_clip(assistantText)}',
        ),
      ]);
      return parseFacts(reply.content);
    } catch (_) {
      // A broken gateway or a bad payload must never break the chat.
      return const [];
    }
  }

  /// Parses the model reply into facts. Accepted shapes, in order:
  /// the raw reply as a JSON array; a fenced ```json block; an array
  /// embedded in surrounding prose; an object carrying the array under any
  /// key. Anything else yields an empty list.
  List<String> parseFacts(String raw) {
    final candidates = <String>[
      raw.trim(),
      for (final match
          in RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false)
              .allMatches(raw))
        match.group(1) ?? '',
      _arraySlice(raw),
    ];
    for (final candidate in candidates) {
      final facts = _decodeFacts(candidate);
      if (facts != null) return facts;
    }
    return const [];
  }

  /// The `[` .. `]` span of a JSON array lost inside prose; '' when absent.
  String _arraySlice(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return '';
    return raw.substring(start, end + 1);
  }

  List<String>? _decodeFacts(String candidate) {
    if (candidate.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } catch (_) {
      return null;
    }
    if (decoded is Map) {
      // Tolerate a wrapper object: use the first list value it carries.
      decoded = decoded.values.firstWhere(
        (value) => value is List,
        orElse: () => null,
      );
    }
    if (decoded is! List) return null;
    final facts = <String>[];
    for (final item in decoded) {
      final text = item is String ? item : _factFromMap(item);
      final trimmed = text.trim();
      if (trimmed.isEmpty || trimmed.length > maxFactChars) continue;
      facts.add(trimmed);
      if (facts.length >= maxFactsPerRound) break;
    }
    return facts;
  }

  /// Tolerates `{"text": ...}` / `{"fact": ...}` style items.
  String _factFromMap(Object? item) {
    if (item is! Map) return '';
    for (final key in const ['text', 'fact', 'content', 'memory']) {
      final value = item[key];
      if (value is String) return value;
    }
    return '';
  }

  String _clip(String text) => text.length > maxInputChars
      ? text.substring(0, maxInputChars)
      : text;
}
