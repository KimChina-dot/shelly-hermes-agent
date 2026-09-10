import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/capability/skills/skill_tool_registry.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/tools/notes_tool.dart';
import 'package:shelly_hermes/skills/builtin_skills.dart';
import 'package:shelly_hermes/skills/skill_registry.dart';

ToolCall _call(String name, [String argumentsJson = '{}']) => ToolCall(
      id: 'call-1',
      name: name,
      argumentsJson: argumentsJson,
    );

SkillToolRegistry _registry({
  bool Function(String capabilityId)? isCapabilityAvailable,
  SkillRegistry? catalog,
}) =>
    SkillToolRegistry(
      registry: catalog ?? buildBuiltinSkillRegistry(),
      isCapabilityAvailable: isCapabilityAvailable ?? (_) => true,
    );

void main() {
  group('SkillToolRegistry specs', () {
    test('exposes list_skills/use_skill as low risk', () {
      final tools = _registry();
      final names = [for (final spec in tools.specs) spec.name];

      expect(names, ['list_skills', 'use_skill']);
      expect(tools.specs.every((spec) => spec.risk == 'low'), isTrue);
    });

    test('openAiToolsJson follows the function-tool shape', () {
      final json = _registry().openAiToolsJson();

      expect(json, hasLength(2));
      for (final entry in json) {
        expect(entry['type'], 'function');
        final function = entry['function'] as Map<String, dynamic>;
        expect(function['description'], isNotEmpty);
        expect(
          (function['parameters'] as Map<String, dynamic>)['type'],
          'object',
        );
      }
      final listSkills = json[0]['function'] as Map<String, dynamic>;
      expect(listSkills['name'], 'list_skills');
      expect(
        (listSkills['parameters'] as Map<String, dynamic>)['properties'],
        isEmpty,
      );
      final useSkill = json[1]['function'] as Map<String, dynamic>;
      expect(useSkill['name'], 'use_skill');
      final properties =
          (useSkill['parameters'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      expect(properties['id'], isA<Map<String, dynamic>>());
      expect(
        (useSkill['parameters'] as Map<String, dynamic>)['required'],
        ['id'],
      );
    });
  });

  group('list_skills', () {
    test('lists every builtin skill as id | name | description | category',
        () async {
      final output = await _registry().execute(_call('list_skills'));
      final lines = output.split('\n');

      expect(lines, hasLength(builtinSkills.length));
      for (final skill in builtinSkills) {
        final line = lines.firstWhere((l) => l.startsWith('${skill.id} | '));
        expect(line, contains(skill.name));
        expect(line, contains(skill.description));
        expect(line.endsWith('| ${skill.category}'), isTrue);
      }
    });

    test('empty catalog answers with a hint string', () async {
      final output =
          await _registry(catalog: SkillRegistry()).execute(_call('list_skills'));

      expect(output, isNotEmpty);
      expect(output, isNot(contains('android_debugging')));
    });
  });

  group('use_skill', () {
    test('returns the roadmap: steps with tools and the guidance block',
        () async {
      final output = await _registry()
          .execute(_call('use_skill', '{"id": "android_debugging"}'));

      expect(output, contains('Android 构建调试'));
      expect(output, contains('android_debugging'));
      expect(output, contains('L2'));
      expect(output, contains('1. 读取完整错误输出'));
      expect(output, contains('[建议工具: run_command]'));
      expect(output, contains('[建议工具: smart_grep, fast_find, read_file]'));
      expect(output, contains('技能指引:'));
      expect(output, contains('禁止未经构建验证就宣称修复完成'));
    });

    test('omits the suggested-tools suffix for steps without tools',
        () async {
      final output = await _registry()
          .execute(_call('use_skill', '{"id": "project_init"}'));

      expect(output, contains('1. 确认项目类型与结构约定\n'), reason: '首步无建议工具,不应带后缀');
    });

    test('unknown id returns an error string naming the available ids',
        () async {
      final output =
          await _registry().execute(_call('use_skill', '{"id": "nope"}'));

      expect(output, startsWith('error:'));
      expect(output, contains('nope'));
      for (final skill in builtinSkills) {
        expect(output, contains(skill.id));
      }
    });

    test('missing id argument returns an error string', () async {
      final output = await _registry().execute(_call('use_skill'));

      expect(output, startsWith('error:'));
      expect(output, contains('"id"'));
    });

    test('names the missing capabilities when the predicate denies them',
        () async {
      final tools = _registry(isCapabilityAvailable: (id) => id != 'terminal');
      final output = await tools
          .execute(_call('use_skill', '{"id": "android_debugging"}'));

      expect(output, startsWith('error:'));
      expect(output, contains('terminal'));
      expect(output, isNot(contains('技能指引:')));
    });

    test('succeeds when every required capability is available', () async {
      final tools =
          _registry(isCapabilityAvailable: (id) => id != 'something_else');
      final output = await tools
          .execute(_call('use_skill', '{"id": "android_debugging"}'));

      expect(output, contains('技能指引:'));
    });
  });

  group('CompositeToolRegistry dispatch', () {
    test('routes skill tool calls to the SkillToolRegistry by name',
        () async {
      final composite = CompositeToolRegistry([
        NotesToolRegistry(),
        _registry(isCapabilityAvailable: (id) => id != 'terminal'),
      ]);

      expect(
        composite.specs.map((spec) => spec.name),
        containsAll(['plan', 'note', 'list_skills', 'use_skill']),
      );
      final listed = await composite.execute(_call('list_skills'));
      expect(listed, contains('file_discovery'));

      final denied =
          await composite.execute(_call('use_skill', '{"id": "git_safety"}'));
      expect(denied, startsWith('error:'));
      expect(denied, contains('terminal'));

      final roadmap = await composite
          .execute(_call('use_skill', '{"id": "file_discovery"}'));
      expect(roadmap, contains('技能指引:'));
    });
  });
}
