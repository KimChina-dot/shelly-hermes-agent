import 'skill_definition.dart';

/// Skill 注册表(v3.0 §60):注册/查找/按任务提示词匹配。
///
/// [lookupByTaskHint] 用关键词重合度打分(与 CapabilityRouter 同一算法),
/// 把用户的自然语言路由到最合适的 Skill。
class SkillRegistry {
  final Map<String, SkillDefinition> _byId = {};

  /// 注册(按 id 幂等)。
  void register(SkillDefinition skill) {
    _byId[skill.id] = skill;
  }

  SkillDefinition? byId(String id) => _byId[id];

  List<SkillDefinition> byCategory(String category) =>
      [for (final s in _byId.values) if (s.category == category) s];

  /// 全部注册的 Skill(注册顺序)。
  List<SkillDefinition> all() => List.unmodifiable(_byId.values);

  int get length => _byId.length;

  /// 按任务提示词打分排序,最匹配的在前;无可匹配时返回空。
  List<SkillDefinition> lookupByTaskHint(String taskHint) {
    final hintTokens = _tokens(taskHint);
    if (hintTokens.isEmpty) return const [];
    final scored = <(SkillDefinition, int)>[];
    for (final skill in _byId.values) {
      final haystack = _tokens([
        skill.name,
        skill.description,
        for (final step in skill.steps) step.description,
      ].join(' '));
      var hits = 0;
      for (final token in hintTokens) {
        if (haystack.contains(token)) hits++;
      }
      if (hits > 0) scored.add((skill, hits));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (skill, _) in scored) skill];
  }

  static Set<String> _tokens(String text) {
    final tokens = <String>{};
    for (final token in text
        .toLowerCase()
        .split(RegExp(r'[\s,，。.:;；/\\()()【】\[\]+\-_]+'))) {
      if (token.isEmpty) continue;
      tokens.add(token);
      // 中文无分词:补 bigram 让"构建失败"能与"构建或运行时错误"重合。
      for (var i = 0; i + 2 <= token.length; i++) {
        final run = token.codeUnitAt(i);
        final isCjk = run >= 0x4E00 && run <= 0x9FFF;
        if (isCjk) tokens.add(token.substring(i, i + 2));
      }
    }
    return tokens;
  }
}
