import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/notes_tool.dart';
import 'package:shelly_hermes/core/tools/registry.dart';

ToolCall _call(String name, Map<String, dynamic> args) =>
    ToolCall(id: 't1', name: name, argumentsJson: jsonEncode(args));

void main() {
  group('NotesToolRegistry plan', () {
    test('acks with the step count and records the plan', () async {
      final notes = NotesToolRegistry();
      expect(
        await notes.execute(
          _call('plan', {
            'steps': ['梳理需求', '实现功能', '回归验证'],
          }),
        ),
        'plan updated (3 steps)',
      );
      expect(notes.recitationBlock(), '「当前计划」\n1. 梳理需求\n2. 实现功能\n3. 回归验证');
    });

    test('replaces (not appends) the previous plan', () async {
      final notes = NotesToolRegistry();
      await notes.execute(
        _call('plan', {
          'steps': ['旧步骤一', '旧步骤二'],
        }),
      );
      expect(
        await notes.execute(
          _call('plan', {
            'steps': ['新步骤'],
          }),
        ),
        'plan updated (1 steps)',
      );
      expect(notes.recitationBlock(), '「当前计划」\n1. 新步骤');
    });

    test('rejects non-string-array steps with an error string', () async {
      final notes = NotesToolRegistry();
      expect(
        await notes.execute(_call('plan', {})),
        'error: plan requires "steps" to be an array of strings',
      );
      expect(
        await notes.execute(
          _call('plan', {
            'steps': ['ok', 42],
          }),
        ),
        'error: plan requires "steps" to be an array of strings',
      );
      // The failed call must not have touched the previous plan.
      await notes.execute(
        _call('plan', {
          'steps': ['保留'],
        }),
      );
      await notes.execute(_call('plan', {}));
      expect(notes.recitationBlock(), '「当前计划」\n1. 保留');
    });
  });

  group('NotesToolRegistry note', () {
    test('acks and appends notes in order', () async {
      final notes = NotesToolRegistry();
      expect(
        await notes.execute(_call('note', {'text': '已完成调研'})),
        'note recorded',
      );
      expect(
        await notes.execute(_call('note', {'text': '发现性能瓶颈'})),
        'note recorded',
      );
      expect(notes.recitationBlock(), '「当前计划」\n最新进展:\n- 已完成调研\n- 发现性能瓶颈');
    });

    test('rejects missing or empty text with an error string', () async {
      final notes = NotesToolRegistry();
      expect(
        await notes.execute(_call('note', {})),
        'error: note requires a non-empty "text"',
      );
      expect(
        await notes.execute(_call('note', {'text': '   '})),
        'error: note requires a non-empty "text"',
      );
      expect(notes.recitationBlock(), isNull);
    });

    test('unknown tools still raise ToolError', () {
      expect(
        NotesToolRegistry().execute(
          const ToolCall(id: 't1', name: 'nope', argumentsJson: '{}'),
        ),
        throwsA(isA<ToolError>()),
      );
    });
  });

  group('NotesToolRegistry recitationBlock caps', () {
    test('caps numbered steps at the first 8', () async {
      final notes = NotesToolRegistry();
      final steps = [for (var i = 1; i <= 10; i++) '步骤$i'];
      await notes.execute(_call('plan', {'steps': steps}));
      final block = notes.recitationBlock()!;
      expect(block.split('\n'), hasLength(9)); // header + 8 steps
      expect(block, contains('1. 步骤1'));
      expect(block, contains('8. 步骤8'));
      expect(block, isNot(contains('步骤9')));
      expect(block, isNot(contains('步骤10')));
    });

    test('caps bullets at the latest 8 notes', () async {
      final notes = NotesToolRegistry();
      for (var i = 1; i <= 10; i++) {
        await notes.execute(_call('note', {'text': '进展$i'}));
      }
      final block = notes.recitationBlock()!;
      final lines = block.split('\n');
      expect(lines, hasLength(10)); // header + label + 8 bullets
      expect(lines[0], '「当前计划」');
      expect(lines[1], '最新进展:');
      expect(block, contains('- 进展3'));
      expect(block, contains('- 进展10'));
      expect(block, isNot(contains('- 进展1\n')));
      expect(block, isNot(contains('进展2')));
    });

    test('shows steps and latest notes together, steps first', () async {
      final notes = NotesToolRegistry();
      await notes.execute(
        _call('plan', {
          'steps': ['目标一', '目标二'],
        }),
      );
      await notes.execute(_call('note', {'text': '推进中'}));
      expect(notes.recitationBlock(), '「当前计划」\n1. 目标一\n2. 目标二\n最新进展:\n- 推进中');
    });
  });

  group('NotesToolRegistry lifecycle', () {
    test('empty state renders null', () {
      expect(NotesToolRegistry().recitationBlock(), isNull);
    });

    test('clearing the plan without notes renders null again', () async {
      final notes = NotesToolRegistry();
      await notes.execute(
        _call('plan', {
          'steps': ['会被清空的步骤'],
        }),
      );
      expect(notes.recitationBlock(), isNotNull);
      expect(
        await notes.execute(_call('plan', {'steps': <String>[]})),
        'plan updated (0 steps)',
      );
      expect(notes.recitationBlock(), isNull);
    });

    test('registries isolate their state', () async {
      final a = NotesToolRegistry();
      final b = NotesToolRegistry();
      await a.execute(
        _call('plan', {
          'steps': ['A 的步骤'],
        }),
      );
      await a.execute(_call('note', {'text': 'A 的备注'}));
      expect(b.recitationBlock(), isNull);
      expect(
        await b.execute(_call('plan', {'steps': <String>[]})),
        'plan updated (0 steps)',
      );
      expect(a.recitationBlock(), '「当前计划」\n1. A 的步骤\n最新进展:\n- A 的备注');
      expect(b.recitationBlock(), isNull);
    });

    test('advertises plan/note specs and OpenAI schemas', () {
      final notes = NotesToolRegistry();
      expect(notes.specs.map((spec) => spec.name), ['plan', 'note']);
      final tools = notes.openAiToolsJson();
      expect(tools, hasLength(2));
      expect(tools[0]['function']['name'], 'plan');
      expect(tools[0]['function']['parameters']['required'], ['steps']);
      expect(tools[1]['function']['name'], 'note');
      expect(tools[1]['function']['parameters']['required'], ['text']);
    });
  });

  group('spliceRecitation', () {
    const persona = '你是 Shelly。\n\n「工具使用守则」\n- 规则A\n- 规则B';
    const memory = '「长期记忆」以下是长期记忆:\n- 用户偏好中文';

    test('inserts the block after the rules and before the memory', () {
      final spliced = spliceRecitation(
        '$persona\n\n$memory',
        '「当前计划」\n1. 目标\n最新进展:\n- 备注',
      );
      expect(spliced, '$persona\n\n「当前计划」\n1. 目标\n最新进展:\n- 备注\n\n$memory');
      final blockAt = spliced.indexOf('「当前计划」');
      expect(blockAt, greaterThan(spliced.indexOf('「工具使用守则」')));
      expect(blockAt, lessThan(spliced.indexOf(memoryBlockMarker)));
    });

    test('appends at the end when there is no memory block', () {
      final spliced = spliceRecitation(persona, '「当前计划」\n1. 目标');
      expect(spliced, '$persona\n\n「当前计划」\n1. 目标');
    });

    test('replaces a stale block across rounds (latest wins)', () {
      final round1 = spliceRecitation('$persona\n\n$memory', '「当前计划」\n1. 旧目标');
      final round2 = spliceRecitation(round1, '「当前计划」\n1. 新目标');
      expect('「当前计划」'.allMatches(round2), hasLength(1));
      expect(round2, '$persona\n\n「当前计划」\n1. 新目标\n\n$memory');
    });

    test('null block strips a stale block and keeps the rest', () {
      final withBlock = spliceRecitation(
        '$persona\n\n$memory',
        '「当前计划」\n1. 旧目标',
      );
      final stripped = spliceRecitation(withBlock, null);
      expect(stripped, '$persona\n\n$memory');
    });

    test('content without any known markers passes through', () {
      expect(
        spliceRecitation('普通系统提示', '「当前计划」\n1. 目标'),
        '普通系统提示\n\n「当前计划」\n1. 目标',
      );
      expect(spliceRecitation('普通系统提示', null), '普通系统提示');
    });
  });
}
