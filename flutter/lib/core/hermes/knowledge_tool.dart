import '../models.dart';
import '../runtime/tool_registry.dart';
import '../tools/registry.dart';
import '../tools/workspace.dart';
import 'hermes_memory.dart';
import 'knowledge.dart';
import 'knowledge_store.dart';

/// PHASE 08: lets the agent record short, reusable lessons mid-task
/// instead of waiting for auto-capture. Memory files live under `.shelly/`
/// / the knowledge ledger, never in project code, so the tool is trusted
/// (allow) — the ledger stays Shelly-owned.
class KnowledgeToolRegistry implements AgentToolRegistry {
  KnowledgeToolRegistry({required this.store});

  final HermesKnowledgeStore store;

  static const knowledgeSpecs = <ToolSpec>[
    ToolSpec(
      'append_knowledge',
      '记录一条简短、可复用的经验/偏好/事实到 Hermes 记忆账本',
      'low',
    ),
  ];

  @override
  List<ToolSpec> get specs => knowledgeSpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        {
          'type': 'function',
          'function': {
            'name': 'append_knowledge',
            'description': knowledgeSpecs.single.description,
            'parameters': {
              'type': 'object',
              'properties': {
                'content': {
                  'type': 'string',
                  'description': '一条简短经验(≤300 字,单句最佳)',
                },
                'category': {
                  'type': 'string',
                  'description': '可选:lesson/preference/fact/pattern,默认 lesson',
                },
              },
              'required': ['content'],
            },
          },
        },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    if (call.name != 'append_knowledge') {
      throw ToolError('unknown tool: ${call.name}');
    }
    final args = decodeArguments(call.argumentsJson);
    final content = args['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const ToolArgumentsException('missing or empty "content"');
    }
    final category = args['category'] is String && (args['category'] as String).isNotEmpty
        ? args['category'] as String
        : 'lesson';
    final trimmed = content.trim().length > 300
        ? '${content.trim().substring(0, 300)}…'
        : content.trim();
    final entry = KnowledgeEntry(
      id: nextEntryId(),
      content: trimmed,
      category: category,
      source: 'agent',
      project: store.project,
    );
    await store.append(entry);
    final total = (await store.loadAll()).length;
    return 'recorded: ${entry.id} (ledger now $total entries)';
  }
}
