/// PHASE 5 (v3.0 §23/§60): Skill 层的数据模型。
///
/// Skill 与 Tool 的分界(§23):Tool 回答"我能做什么动作"(read_file /
/// run_command / …),Skill 回答"我知道如何完成什么类型的问题"(Android
/// 调试 / 代码重构 / …)。一个 Skill 由多个 Tool 的编排顺序 + 针对性提示词
/// 构成;Agent 仍通过 plan/note 工具自己驱动执行——Skill 提供的是路线图,
/// 不是可执行管道。
library;

import 'package:flutter/foundation.dart';

/// 一个 Skill 内部的执行步骤模板。
///
/// [suggestedTools] 是建议优先使用的工具 id 列表(如 `smart_grep`、
/// `run_command`),Agent 可根据实际情况替换。
@immutable
class SkillStep {
  const SkillStep({
    required this.description,
    this.suggestedTools = const [],
  });

  final String description;
  final List<String> suggestedTools;

  SkillStep copyWith({String? description, List<String>? suggestedTools}) =>
      SkillStep(
        description: description ?? this.description,
        suggestedTools: suggestedTools ?? this.suggestedTools,
      );

  @override
  bool operator ==(Object other) =>
      other is SkillStep &&
      other.description == description &&
      other.suggestedTools == suggestedTools;

  @override
  int get hashCode => Object.hash(description, Object.hashAll(suggestedTools));
}

/// Skill 定义:一个可复用的问题类型解决路线。
@immutable
class SkillDefinition {
  const SkillDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.steps,
    required this.requiredCapabilities,
    this.riskLevel = 'L0',
    required this.promptGuidance,
  });

  final String id;
  final String name;
  final String description;
  final String category;

  /// L0-L4,与 Capability 风险分级一致。
  final String riskLevel;

  /// 编排步骤模板;Agent 按此路线自行驱动工具。
  final List<SkillStep> steps;

  /// 依赖的能力 id(对应 CapabilityRegistry 的 id),用于激活前检查。
  final List<String> requiredCapabilities;

  /// 激活此 Skill 时的系统提示词附加段(把领域经验写进上下文)。
  final String promptGuidance;

  SkillDefinition copyWith({
    String? name,
    String? description,
    List<SkillStep>? steps,
    List<String>? requiredCapabilities,
    String? promptGuidance,
  }) =>
      SkillDefinition(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        category: category,
        steps: steps ?? this.steps,
        requiredCapabilities:
            requiredCapabilities ?? this.requiredCapabilities,
        riskLevel: riskLevel,
        promptGuidance: promptGuidance ?? this.promptGuidance,
      );

  @override
  bool operator ==(Object other) =>
      other is SkillDefinition &&
      other.id == id &&
      other.name == name &&
      other.category == category;

  @override
  int get hashCode => Object.hash(id, name, category);
}

/// Skill 风险级别沿用 Capability 的 L0-L4 分级(见 capability.dart)。
typedef SkillRiskLevel = String;
