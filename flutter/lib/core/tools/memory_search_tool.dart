import 'dart:convert';

import '../crash/crash_log_store.dart';
import '../memory/memory_store.dart';
import '../models.dart';
import '../runtime/tool_registry.dart';
import '../tools/registry.dart';
import '../tools/workspace.dart' show decodeArguments;
import '../../state/settings_store.dart' show ConversationSummary;

/// Self-diagnosis memory search (PHASE 43): `search_memory` lets the agent
/// grep its own history — past conversation checkpoints and recorded crash
/// logs — instead of asking the user to repeat context. Hits carry the
/// surrounding messages (before/after, analogous to grep's ±5 lines) and
/// the conversation id/title so the agent can cite them.
///
/// PHASE 52 adds the `memory` scope: tiered facts from [MemoryFact] stores
/// become greppable here. Because archival facts never auto-inject into the
/// prompt, they are reachable ONLY through this tool.
///
/// All loaders are injected; any loader failure is swallowed into an empty
/// result with an `error` note — a broken history store must never break
/// the tool surface.
class MemorySearchToolRegistry implements AgentToolRegistry {
  MemorySearchToolRegistry({
    required this.loadSummaries,
    required this.loadCheckpoint,
    this.loadCrashes,
    this.loadFacts,
  });

  final List<ConversationSummary> Function() loadSummaries;
  final AgentCheckpoint? Function(String id) loadCheckpoint;

  /// Null → the crash scope is reported as unavailable.
  final List<CrashEntry> Function()? loadCrashes;

  /// Null → the memory scope is skipped (and reported as unavailable when
  /// requested explicitly). Absent wiring must never break the tool.
  final List<MemoryFact> Function()? loadFacts;

  static const memorySpecs = <ToolSpec>[
    ToolSpec(
      'search_memory',
      '检索过往对话、长期记忆事实与崩溃日志,返回带上下文的结构化 JSON',
      'low',
    ),
  ];

  @override
  List<ToolSpec> get specs => memorySpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        {
          'type': 'function',
          'function': {
            'name': 'search_memory',
            'description': memorySpecs.single.description,
            'parameters': {
              'type': 'object',
              'properties': {
                'pattern': {
                  'type': 'string',
                  'description': '要检索的关键词(大小写不敏感)',
                },
                'scope': {
                  'type': 'string',
                  'description':
                      "可选,'conversation' | 'crash' | 'memory' | 'all'(默认 all)",
                },
                'max_results': {
                  'type': 'number',
                  'description': '可选,最多返回命中数(默认 10,上限 30)',
                },
              },
              'required': ['pattern'],
            },
          },
        },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    if (call.name != 'search_memory') {
      throw ToolError('unknown tool: ${call.name}');
    }
    final args = decodeArguments(call.argumentsJson);
    final pattern = args['pattern'];
    if (pattern is! String || pattern.trim().isEmpty) {
      return _errorJson('search_memory requires a non-empty "pattern"');
    }
    final scopeRaw = args['scope'];
    if (scopeRaw != null &&
        (scopeRaw is! String ||
            !const ['conversation', 'crash', 'memory', 'all']
                .contains(scopeRaw))) {
      return _errorJson(
          '"scope" must be "conversation", "crash", "memory" or "all"');
    }
    final scope = (scopeRaw as String?) ?? 'all';
    final maxResults = _clampedInt(args['max_results'], 1, 30, 10);
    final needle = pattern.trim().toLowerCase();

    final hits = <Map<String, dynamic>>[];
    final notes = <String>[];

    if (scope == 'conversation' || scope == 'all') {
      try {
        for (final summary in loadSummaries()) {
          if (hits.length >= maxResults) break;
          final checkpoint = loadCheckpoint(summary.id);
          if (checkpoint == null) continue;
          _collectConversationHits(
            checkpoint: checkpoint,
            summary: summary,
            needle: needle,
            hits: hits,
            maxResults: maxResults,
          );
        }
      } catch (e) {
        notes.add('conversation history unavailable: $e');
      }
    }

    if (scope == 'crash' || scope == 'all') {
      final crashes = loadCrashes;
      if (crashes == null) {
        if (scope == 'crash') notes.add('crash log store not wired');
      } else {
        try {
          for (final entry in crashes()) {
            if (hits.length >= maxResults) break;
            final hay = '${entry.error}\n${entry.stack}'.toLowerCase();
            if (!hay.contains(needle)) continue;
            hits.add({
              'scope': 'crash',
              'crashAt': entry.at.toIso8601String(),
              'crashContext': entry.context,
              'text': entry.error,
              'after': entry.stack
                  .split('\n')
                  .take(5)
                  .where((line) => line.trim().isNotEmpty)
                  .toList(),
              'before': <String>[],
            });
          }
        } catch (e) {
          notes.add('crash log store unavailable: $e');
        }
      }
    }

    if (scope == 'memory' || scope == 'all') {
      final facts = loadFacts;
      if (facts == null) {
        if (scope == 'memory') notes.add('memory store not wired');
      } else {
        try {
          for (final fact in facts()) {
            if (hits.length >= maxResults) break;
            if (!fact.text.toLowerCase().contains(needle)) continue;
            hits.add({
              'scope': 'memory',
              'tier': fact.tier.name,
              'text': fact.text,
              'createdAt': fact.createdAt.toIso8601String(),
              'before': <String>[],
              'after': <String>[],
            });
          }
        } catch (e) {
          notes.add('memory store unavailable: $e');
        }
      }
    }

    return jsonEncode({
      if (notes.isNotEmpty) 'error': notes.join('; '),
      'hits': hits,
      'total': hits.length,
      'truncated': hits.length >= maxResults,
    });
  }

  void _collectConversationHits({
    required AgentCheckpoint checkpoint,
    required ConversationSummary summary,
    required String needle,
    required List<Map<String, dynamic>> hits,
    required int maxResults,
  }) {
    final messages = checkpoint.messages;
    for (var i = 0; i < messages.length; i++) {
      if (hits.length >= maxResults) return;
      final message = messages[i];
      if (message.role != MessageRole.user &&
          message.role != MessageRole.assistant) {
        continue;
      }
      if (!message.content.toLowerCase().contains(needle)) continue;
      hits.add({
        'scope': 'conversation',
        'conversationId': summary.id,
        'conversationTitle': summary.title,
        'role': message.role.name,
        'text': message.content,
        'before': [
          for (var j = i - 1; j >= 0 && j >= i - 5; j--)
            if (messages[j].role == MessageRole.user ||
                messages[j].role == MessageRole.assistant)
              '${messages[j].role.name}: ${messages[j].content}',
        ].reversed.toList(),
        'after': [
          for (var j = i + 1;
              j < messages.length && j <= i + 5;
              j++)
            if (messages[j].role == MessageRole.user ||
                messages[j].role == MessageRole.assistant)
              '${messages[j].role.name}: ${messages[j].content}',
        ],
      });
    }
  }

  int _clampedInt(dynamic value, int min, int max, int fallback) {
    if (value is! num) return fallback;
    return value.toInt().clamp(min, max);
  }

  String _errorJson(String message) =>
      jsonEncode({'error': message, 'hits': <dynamic>[], 'total': 0});
}
