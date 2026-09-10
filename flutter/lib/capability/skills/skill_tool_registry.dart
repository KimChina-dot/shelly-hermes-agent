import '../../core/models.dart';
import '../../core/runtime/tool_registry.dart';
import '../../core/tools/registry.dart';
import '../../core/tools/workspace.dart' show decodeArguments;
import '../../skills/skill_definition.dart';
import '../../skills/skill_registry.dart';

/// PHASE 9 (v3.0 §23/§60): exposes the built-in Skills on the model tool
/// surface as two read-only tools, `list_skills` and `use_skill`.
///
/// A Skill is a prompt roadmap, not an executable pipeline (PHASE 5):
/// `use_skill` hands the model the skill's step template plus its
/// [SkillDefinition.promptGuidance], and the agent then drives the real
/// tools itself — nothing is executed by these tools. Neither tool issues
/// model calls or touches the workspace, so both carry risk 'low' and are
/// safe to auto-approve (see `_NotesStateApprovalPolicy`).
///
/// Invalid input (unknown skill id, missing argument, unavailable required
/// capability) returns an error string — never an exception — so the model
/// can correct itself without failing the task, mirroring
/// [NotesToolRegistry]. One instance lives per task run (like the other
/// registries), built over [buildBuiltinSkillRegistry] by the session.
class SkillToolRegistry implements AgentToolRegistry {
  SkillToolRegistry({
    required this.registry,
    required this.isCapabilityAvailable,
  });

  /// Skill catalog both tools read from (typically the built-ins).
  final SkillRegistry registry;

  /// Whether a capability id (CapabilityRegistry ids, PHASE 4) is usable in
  /// the current task. Checked against each skill's
  /// [SkillDefinition.requiredCapabilities] before the roadmap is handed
  /// out, so the model never starts a route it cannot finish.
  final bool Function(String capabilityId) isCapabilityAvailable;

  static const skillSpecs = <ToolSpec>[
    ToolSpec('list_skills', '列出全部可用技能(id | 名称 | 描述 | 分类)', 'low'),
    ToolSpec(
      'use_skill',
      '激活一个技能:返回它的分步路线图与技能指引(只是提示词,不执行任何操作)',
      'low',
    ),
  ];

  @override
  List<ToolSpec> get specs => skillSpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        {
          'type': 'function',
          'function': {
            'name': 'list_skills',
            'description': skillSpecs[0].description,
            'parameters': {
              'type': 'object',
              'properties': <String, dynamic>{},
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'use_skill',
            'description': skillSpecs[1].description,
            'parameters': {
              'type': 'object',
              'properties': {
                'id': {
                  'type': 'string',
                  'description': '要激活的技能 id(来自 list_skills 的第一列)',
                },
              },
              'required': ['id'],
            },
          },
        },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    switch (call.name) {
      case 'list_skills':
        return _listSkills();
      case 'use_skill':
        return _useSkill(call);
      default:
        throw ToolError('unknown tool: ${call.name}');
    }
  }

  /// One line per skill: `id | 名称 | 描述 | 分类`. An empty registry gets
  /// a hint string instead of silence.
  Future<String> _listSkills() async {
    if (registry.length == 0) {
      return '当前没有已注册的技能';
    }
    return [
      for (final skill in registry.all())
        '${skill.id} | ${skill.name} | ${skill.description} | ${skill.category}',
    ].join('\n');
  }

  /// Returns the skill's roadmap text: name, risk level, numbered steps
  /// (each with optional `[建议工具: …]`) and the 「技能指引」 paragraph.
  Future<String> _useSkill(ToolCall call) async {
    final args = decodeArguments(call.argumentsJson);
    final id = args['id'];
    if (id is! String || id.trim().isEmpty) {
      return 'error: use_skill requires a non-empty "id"';
    }
    final skill = registry.byId(id.trim());
    if (skill == null) {
      final available =
          [for (final s in registry.all()) s.id].join(', ');
      return 'error: unknown skill id "$id". '
          'available skills: ${available.isEmpty ? '(none)' : available}';
    }
    final missing = [
      for (final capabilityId in skill.requiredCapabilities)
        if (!isCapabilityAvailable(capabilityId)) capabilityId,
    ];
    if (missing.isNotEmpty) {
      return 'error: skill "$id" requires capabilities that are not '
          'available: ${missing.join(', ')}';
    }
    return _roadmap(skill);
  }

  String _roadmap(SkillDefinition skill) {
    final lines = <String>[
      '技能「${skill.name}」(${skill.id}),风险级别 ${skill.riskLevel}',
      '执行步骤:',
    ];
    for (var i = 0; i < skill.steps.length; i++) {
      final step = skill.steps[i];
      final tools = step.suggestedTools.isEmpty
          ? ''
          : ' [建议工具: ${step.suggestedTools.join(', ')}]';
      lines.add('${i + 1}. ${step.description}$tools');
    }
    lines
      ..add('技能指引:')
      ..add(skill.promptGuidance);
    return lines.join('\n');
  }
}
