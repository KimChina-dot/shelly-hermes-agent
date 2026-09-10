import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/skills/builtin_skills.dart';
import 'package:shelly_hermes/skills/skill_registry.dart';

void main() {
  group('SkillRegistry', () {
    test('register + byId + all, idempotent by id', () {
      final registry = SkillRegistry();
      registry.register(builtinSkills[0]);
      registry.register(builtinSkills[0].copyWith(name: '替换'));
      registry.register(builtinSkills[1]);

      expect(registry.length, 2);
      expect(registry.byId(builtinSkills[0].id)?.name, '替换');
    });

    test('byCategory filters', () {
      final registry = SkillRegistry();
      for (final skill in builtinSkills) {
        registry.register(skill);
      }
      expect(
        registry.byCategory('debugging').map((s) => s.id),
        ['android_debugging'],
      );
      expect(registry.byCategory('不存在的类目'), isEmpty);
    });

    test('lookupByTaskHint ranks android build failures first', () {
      final registry = buildBuiltinSkillRegistry();
      final ranked = registry.lookupByTaskHint('APK 构建失败了,帮我修复构建错误');
      expect(ranked.first.id, 'android_debugging');
    });

    test('lookupByTaskHint ranks search intent to file_discovery', () {
      final registry = buildBuiltinSkillRegistry();
      final ranked = registry.lookupByTaskHint('按名称模式查找候选文件并缩小范围');
      expect(ranked.first.id, 'file_discovery');
    });

    test('lookupByTaskHint returns empty for unrelated hints', () {
      final registry = buildBuiltinSkillRegistry();
      expect(registry.lookupByTaskHint('你好'), isEmpty);
    });
  });

  group('builtin skills integrity', () {
    test('ids are unique and non-empty', () {
      final ids = builtinSkills.map((s) => s.id).toSet();
      expect(ids.length, builtinSkills.length);
      expect(builtinSkills.every((s) => s.id.isNotEmpty), isTrue);
    });

    test('every skill has steps and guidance', () {
      for (final skill in builtinSkills) {
        expect(skill.steps, isNotEmpty, reason: '${skill.id} 缺少步骤');
        expect(skill.promptGuidance, isNotEmpty,
            reason: '${skill.id} 缺少提示词');
      }
    });

    test('required capabilities reference real Phase-4 ids', () {
      const knownCapabilities = {
        'filesystem',
        'terminal',
        'memory',
        'knowledge',
      };
      for (final skill in builtinSkills) {
        for (final cap in skill.requiredCapabilities) {
          expect(knownCapabilities, contains(cap),
              reason: '${skill.id} 引用了未知能力 $cap');
        }
      }
    });

    test('step suggested tools reference real tool ids', () {
      const knownTools = {
        'read_file',
        'write_file',
        'exists',
        'list_files',
        'search_files',
        'apply_patch',
        'run_command',
        'fast_find',
        'smart_grep',
        'search_memory',
        'plan',
        'note',
      };
      for (final skill in builtinSkills) {
        for (final step in skill.steps) {
          for (final tool in step.suggestedTools) {
            expect(knownTools, contains(tool),
                reason: '${skill.id} 引用了未知工具 $tool');
          }
        }
      }
    });

    test('built-in registry preloads all skills', () {
      final registry = buildBuiltinSkillRegistry();
      expect(registry.length, builtinSkills.length);
      for (final skill in builtinSkills) {
        expect(registry.byId(skill.id), isNotNull);
      }
    });
  });
}
