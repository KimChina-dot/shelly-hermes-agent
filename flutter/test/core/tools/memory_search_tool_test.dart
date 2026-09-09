import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/crash/crash_log_store.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/memory_search_tool.dart';
import 'package:shelly_hermes/state/settings_store.dart';

AgentCheckpoint _checkpoint(List<(MessageRole, String)> turns) =>
    AgentCheckpoint(
      messages: [
        for (final (role, content) in turns)
          AgentMessage(role: role, content: content),
      ],
      round: 1,
      consumedTokens: 0,
      toolCalls: 0,
    );

ToolCall _call(Map<String, dynamic> args) =>
    ToolCall(id: 't1', name: 'search_memory', argumentsJson: jsonEncode(args));

void main() {
  final summaries = [
    ConversationSummary(
      id: 'conv-1',
      title: '构建报错排查',
      updatedAt: DateTime(2026),
      messageCount: 4,
    ),
    ConversationSummary(
      id: 'conv-2',
      title: '闲聊',
      updatedAt: DateTime(2026),
      messageCount: 2,
    ),
  ];
  final checkpoints = {
    'conv-1': _checkpoint([
      (MessageRole.user, '构建失败了报 Null safety 错误'),
      (MessageRole.assistant, '请运行 flutter analyze 查看详细输出'),
      (MessageRole.user, '输出指向 settings_store.dart 第 42 行'),
      (MessageRole.assistant, '那是空安全迁移问题,把 var 改成 final'),
    ]),
    'conv-2': _checkpoint([
      (MessageRole.user, '今天天气怎么样'),
      (MessageRole.assistant, '我无法访问实时天气数据'),
    ]),
  };

  group('MemorySearchToolRegistry search_memory', () {
    test('finds a hit in an assistant message with before/after context',
        () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': 'flutter analyze'})))
          as Map<String, dynamic>;

      expect(json['total'], 1);
      final hit = (json['hits'] as List)
          .map((h) => h as Map)
          .reduce((a, b) => a);
      expect(hit['role'], 'assistant');
      expect(hit['conversationId'], 'conv-1');
      expect(hit['conversationTitle'], '构建报错排查');
      expect(hit['role'], 'assistant');
      expect(hit['text'], contains('flutter analyze'));
      expect((hit['before'] as List).single, contains('Null safety'));
      expect(hit['after'], hasLength(2));
      expect((hit['after'] as List).first, contains('第 42 行'));
    });

    test('is case-insensitive and hits user messages too', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(
              await registry.execute(_call({'pattern': 'NULL SAFETY'})))
          as Map<String, dynamic>;
      expect(json['total'], 1);
      expect(((json['hits'] as List).single as Map)['role'], 'user');
    });

    test('scope filtering: conversation-only skips crash store', () async {
      var crashesRead = false;
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadCrashes: () {
          crashesRead = true;
          return [
            CrashEntry(
              at: DateTime(2026),
              context: 'flutter',
              error: 'flutter analyze boom',
              stack: 'stack line',
            ),
          ];
        },
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': 'flutter', 'scope': 'conversation'})))
          as Map<String, dynamic>;
      expect(crashesRead, false);
      expect((json['hits'] as List).every((h) => h['scope'] == 'conversation'),
          true);
    });

    test('crash-scope hits include stack context', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadCrashes: () => [
          CrashEntry(
            at: DateTime.utc(2026, 9, 6, 12),
            context: 'platform',
            error: 'socket reset during stream',
            stack: 'at line 1\nat line 2',
          ),
        ],
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': 'socket reset', 'scope': 'crash'})))
          as Map<String, dynamic>;
      expect(json['total'], 1);
      final hit = (json['hits'] as List).single as Map;
      expect(hit['crashContext'], 'platform');
      expect(hit['crashAt'], '2026-09-06T12:00:00.000Z');
      expect((hit['after'] as List), hasLength(2));
    });

    test('null crash loader reports crash scope unavailable', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': 'anything', 'scope': 'crash'})))
          as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json['error'], contains('crash'));
    });

    test('blank pattern returns a structured error', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(
          await registry.execute(_call({'pattern': '   '}))) as Map<String, dynamic>;
      expect(json['error'], contains('pattern'));
      expect(json['total'], 0);
    });

    test('loader exceptions are swallowed with an error note', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => throw StateError('prefs broken'),
        loadCheckpoint: (id) => throw StateError('unreachable'),
      );
      final json = jsonDecode(
              await registry.execute(_call({'pattern': 'x'})))
          as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json['error'], contains('conversation history unavailable'));
    });

    test('max_results caps entries and flags truncation', () async {
      final many = _checkpoint([
        for (var i = 0; i < 8; i++) ...[
          (MessageRole.user, '关于部署的第 $i 个问题'),
          (MessageRole.assistant, '部署回答 $i'),
        ],
      ]);
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => [
          ConversationSummary(
              id: 'c', title: 't', updatedAt: DateTime(2026), messageCount: 16),
        ],
        loadCheckpoint: (_) => many,
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': '部署', 'max_results': 3})))
          as Map<String, dynamic>;
      expect(json['total'], 3);
      expect(json['truncated'], true);
    });

    test('no match returns an empty hit list without error', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': '不存在的内容'}))) as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json['hits'], isEmpty);
      expect(json.containsKey('error'), false);
    });

    test('exposes spec and OpenAI schema with the agreed parameter shape',
        () {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      expect(registry.specs.map((s) => s.name), contains('search_memory'));
      final schema = registry.openAiToolsJson().single;
      final params = (schema['function'] as Map)['parameters'] as Map;
      expect((params['properties'] as Map).keys,
          containsAll(['pattern', 'scope', 'max_results']));
      expect((params['required'] as List), ['pattern']);
    });
  });

  group('MemorySearchToolRegistry memory scope (PHASE 52)', () {
    test('memory-scope hits carry tier and empty context, case-insensitive',
        () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadFacts: () => [
          MemoryFact(
            id: 'm1',
            text: '用户喜欢 Dark Theme',
            createdAt: DateTime.utc(2026, 9, 1, 8),
            // Archival facts are the tier that motivated this scope: they
            // never auto-inject, so this tool is their only retrieval path.
            tier: MemoryTier.archival,
          ),
        ],
      );
      final json = jsonDecode(await registry
              .execute(_call({'pattern': 'DARK', 'scope': 'memory'})))
          as Map<String, dynamic>;

      expect(json['total'], 1);
      final hit = (json['hits'] as List).single as Map;
      expect(hit['scope'], 'memory');
      expect(hit['tier'], 'archival');
      expect(hit['text'], '用户喜欢 Dark Theme');
      expect(hit['createdAt'], '2026-09-01T08:00:00.000Z');
      expect(hit['before'], isEmpty);
      expect(hit['after'], isEmpty);
    });

    test('conversation-only scope never reads the memory store', () async {
      var factsRead = false;
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadFacts: () {
          factsRead = true;
          return const [];
        },
      );
      final json = jsonDecode(await registry.execute(
              _call({'pattern': 'flutter analyze', 'scope': 'conversation'})))
          as Map<String, dynamic>;
      expect(factsRead, false);
      expect((json['hits'] as List).every((h) => h['scope'] == 'conversation'),
          true);
    });

    test('default all-scope includes memory hits alongside others', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadCrashes: () => [
          CrashEntry(
            at: DateTime(2026),
            context: 'flutter',
            error: 'flutter analyze boom',
            stack: 'stack line',
          ),
        ],
        loadFacts: () => [
          MemoryFact(
            id: 'm1',
            text: '每次改代码都要跑 flutter analyze',
            createdAt: DateTime.utc(2026, 9, 1),
          ),
        ],
      );
      final json =
          jsonDecode(await registry.execute(_call({'pattern': 'flutter'})))
              as Map<String, dynamic>;
      final scopes =
          (json['hits'] as List).map((h) => (h as Map)['scope']).toSet();
      expect(scopes, containsAll(['conversation', 'crash', 'memory']));
    });

    test('absent loadFacts reports the memory scope unavailable', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(
              await registry.execute(_call({'pattern': 'x', 'scope': 'memory'})))
          as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json['error'], contains('memory'));
    });

    test('absent loadFacts is a silent skip under the default all-scope',
        () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
      );
      final json = jsonDecode(
              await registry.execute(_call({'pattern': '不匹配的内容'})))
          as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json.containsKey('error'), false);
    });

    test('loadFacts exceptions are swallowed with an error note', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadFacts: () => throw StateError('prefs broken'),
      );
      final json = jsonDecode(
              await registry.execute(_call({'pattern': 'x', 'scope': 'memory'})))
          as Map<String, dynamic>;
      expect(json['total'], 0);
      expect(json['error'], contains('memory store unavailable'));
    });

    test('memory hits respect max_results and flag truncation', () async {
      final registry = MemorySearchToolRegistry(
        loadSummaries: () => summaries,
        loadCheckpoint: (id) => checkpoints[id],
        loadFacts: () => [
          for (var i = 0; i < 5; i++)
            MemoryFact(
              id: 'm$i',
              text: '偏好记录 $i',
              createdAt: DateTime.utc(2026, 9, 1),
            ),
        ],
      );
      final json = jsonDecode(await registry.execute(
              _call({'pattern': '偏好', 'scope': 'memory', 'max_results': 2})))
          as Map<String, dynamic>;
      expect(json['total'], 2);
      expect(json['truncated'], true);
    });
  });
}
