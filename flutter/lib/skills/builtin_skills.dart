import 'skill_definition.dart';
import 'skill_registry.dart';

/// 内置 Skill 目录(v3.0 §60):覆盖最常见的问题类型。每个 Skill 的
/// requiredCapabilities 对应 CapabilityRegistry 的 id(Phase 4)。
///
/// Skill 是提示词路线图,不是可执行管道——激活时把 [SkillDefinition
/// .promptGuidance] 注入系统提示,Agent 按步骤模板自行驱动工具。

/// 构建默认注册表:全部内置 Skill 预装。
SkillRegistry buildBuiltinSkillRegistry() {
  final registry = SkillRegistry();
  for (final skill in builtinSkills) {
    registry.register(skill);
  }
  return registry;
}

/// 全部内置 Skill(id 唯一性由测试保证)。
const List<SkillDefinition> builtinSkills = [
  SkillDefinition(
    id: 'android_debugging',
    name: 'Android 构建调试',
    description: '分析并修复 Android 项目的构建或运行时错误。',
    category: 'debugging',
    steps: [
      SkillStep(description: '读取完整错误输出,区分错误类型',
          suggestedTools: ['run_command']),
      SkillStep(description: '按错误信息定位源文件与行号',
          suggestedTools: ['smart_grep', 'fast_find', 'read_file']),
      SkillStep(description: '检查依赖与配置(Gradle/Manifest)'),
      SkillStep(description: '实施最小修改',
          suggestedTools: ['apply_patch']),
      SkillStep(description: '重新构建验证修复', suggestedTools: ['run_command']),
    ],
    requiredCapabilities: ['filesystem', 'terminal'],
    riskLevel: 'L2',
    promptGuidance:
        '修复构建错误时:先完整读错误,再定位,最小化修改。禁止未经构建验证就宣称修复完成。',
  ),
  SkillDefinition(
    id: 'file_discovery',
    name: '文件定位',
    description: '在陌生工作区里按名称或内容快速定位文件。',
    category: 'search',
    steps: [
      SkillStep(description: '按名称模式查找候选文件',
          suggestedTools: ['fast_find', 'list_files']),
      SkillStep(description: '按内容关键词缩小范围',
          suggestedTools: ['smart_grep', 'search_files']),
      SkillStep(description: '读取确认目标文件', suggestedTools: ['read_file']),
    ],
    requiredCapabilities: ['filesystem'],
    riskLevel: 'L0',
    promptGuidance: '先 find 后 grep 再 read:不要一次性全量搜索,利用截断结果。',
  ),
  SkillDefinition(
    id: 'code_refactor',
    name: '代码重构',
    description: '在不改变行为的前提下改进代码结构。',
    category: 'refactoring',
    steps: [
      SkillStep(description: '读取并理解现状', suggestedTools: ['read_file']),
      SkillStep(description: '制定最小改动方案并记录', suggestedTools: ['plan']),
      SkillStep(description: '按 hunk 实施补丁', suggestedTools: ['apply_patch']),
      SkillStep(description: '验证行为未变(测试/构建)',
          suggestedTools: ['run_command']),
    ],
    requiredCapabilities: ['filesystem', 'terminal'],
    riskLevel: 'L1',
    promptGuidance: '重构必须行为等价:小步修改,每步可验证;禁止顺手改无关代码。',
  ),
  SkillDefinition(
    id: 'project_init',
    name: '项目初始化',
    description: '在空白工作区创建一个新项目的骨架。',
    category: 'init',
    steps: [
      SkillStep(description: '确认项目类型与结构约定'),
      SkillStep(description: '创建目录与入口文件',
          suggestedTools: ['write_file']),
      SkillStep(description: '写入配置与依赖清单',
          suggestedTools: ['write_file']),
      SkillStep(description: '验证骨架完整', suggestedTools: ['list_files']),
    ],
    requiredCapabilities: ['filesystem'],
    riskLevel: 'L1',
    promptGuidance: '初始化只搭骨架:宁可少文件,不要一次生成大量未验证代码。',
  ),
  SkillDefinition(
    id: 'git_safety',
    name: 'Git 安全操作',
    description: '查看 Git 状态、理解变更历史、安全地回滚。',
    category: 'git',
    steps: [
      SkillStep(description: '查看当前状态与最近提交',
          suggestedTools: ['run_command']),
      SkillStep(description: '分析变更范围', suggestedTools: ['read_file']),
      SkillStep(description: '给出回滚或提交建议;危险操作必须征得批准',
          suggestedTools: ['run_command']),
    ],
    requiredCapabilities: ['filesystem', 'terminal'],
    riskLevel: 'L2',
    promptGuidance:
        'Git 危险操作(reset --hard / clean / force push)必须先展示影响再请求批准。',
  ),
];
