import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/hermes/forgetting.dart';
import 'package:shelly_hermes/core/hermes/hermes_memory.dart';
import 'package:shelly_hermes/core/hermes/knowledge.dart';
import 'package:shelly_hermes/core/hermes/knowledge_store.dart';
import 'package:shelly_hermes/core/hermes/knowledge_tool.dart';
import 'package:shelly_hermes/core/hermes/reflection.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

KnowledgeEntry entry(
  String id,
  String content, {
  String category = 'lesson',
  DateTime? lastTriggeredAt,
  int frequency = 0,
  String source = 'agent',
}) =>
    KnowledgeEntry(
      id: id,
      content: content,
      category: category,
      lastTriggeredAt: lastTriggeredAt,
      frequency: frequency,
      source: source,
    );

void main() {
  group('KnowledgeEntry JSONL round-trip', () {
    test('toJson/fromJson preserves all fields', () {
      final e = entry('k-1', '登录前先清 token', frequency: 3)
        ..frequency = 3;
      final restored = KnowledgeEntry.fromJson(e.toJson());
      expect(restored.id, 'k-1');
      expect(restored.content, '登录前先清 token');
      expect(restored.frequency, 3);
      expect(restored.category, 'lesson');
    });

    test('estimateTokens: CJK per char, ascii per 4 chars', () {
      expect(estimateTokens('登录'), 2);
      expect(estimateTokens('abcdefgh'), 2);
    });
  });

  group('HermesKnowledgeStore', () {
    late MemoryWorkspace ws;
    late HermesKnowledgeStore store;

    setUp(() {
      ws = MemoryWorkspace();
      store = HermesKnowledgeStore(workspace: ws, project: 'demo');
    });

    test('append persists JSONL and markdown projection', () async {
      await store.append(entry('k-1', 'always run flutter analyze first'));
      await store.append(KnowledgeEntry(
        id: 'k-2',
        content: '构建失败先看 pubspec 版本冲突',
        project: 'demo',
      ));
      final jsonl = ws.files['.shelly/knowledge.jsonl']!;
      expect(jsonl.split('\n').where((l) => l.trim().isNotEmpty).length, 2);
      expect(ws.files['.shelly_knowledge.md'], contains('k-2'));
      expect((await store.loadAll()).length, 2);
      expect((await store.loadAll()).last.project, 'demo');
    });

    test('loadAll skips corrupt lines', () async {
      ws.files['.shelly/knowledge.jsonl'] =
          '{not json}\n${'{"id":"k-ok","content":"good"}'}\n';
      final entries = await store.loadAll();
      expect(entries.length, 1);
      expect(entries.single.id, 'k-ok');
    });

    test('recall scores keyword overlap and bumps frequency', () async {
      await store.append(KnowledgeEntry(
        id: 'k-1',
        content: '登录页崩溃时先清理过期的 session token',
        project: 'demo',
      ));
      await store.append(KnowledgeEntry(
        id: 'k-2',
        content: '数据库迁移前必须备份 schema',
        project: 'demo',
      ));
      final recalled = await store.recall('登录页又崩溃了,session 丢失');
      expect(recalled, hasLength(1));
      expect(recalled.single, contains('登录页崩溃'));
      final after = await store.loadAll();
      expect(after.firstWhere((e) => e.id == 'k-1').frequency, 1);
      expect(after.firstWhere((e) => e.id == 'k-2').frequency, 0);
    });

    test('recall respects token budget across multiple hits', () async {
      final long = 'x' * 1600; // ≈400 tokens
      await store.append(KnowledgeEntry(id: 'k-a', content: long));
      await store.append(KnowledgeEntry(id: 'k-b', content: long));
      await store.append(KnowledgeEntry(id: 'k-c', content: long));
      final recalled = await store.recall('x');
      expect(recalled.length, lessThan(3));
    });
  });

  group('append_knowledge tool', () {
    test('records a short entry and reports ledger size', () async {
      final ws = MemoryWorkspace();
      final tool = KnowledgeToolRegistry(
        store: HermesKnowledgeStore(workspace: ws, project: 'p'),
      );
      final out = await tool.execute(const ToolCall(
        id: 't1',
        name: 'append_knowledge',
        argumentsJson: '{"content":"CI 缓存要先清 flutter pub cache","category":"pattern"}',
      ));
      expect(out, contains('recorded'));
      final entries = await HermesKnowledgeStore(
        workspace: ws,
        project: 'p',
      ).loadAll();
      expect(entries.single.category, 'pattern');
      expect(entries.single.project, 'p');
      expect(entries.single.source, 'agent');
    });

    test('oversized content is clipped to 300 chars', () async {
      final ws = MemoryWorkspace();
      final tool = KnowledgeToolRegistry(
        store: HermesKnowledgeStore(workspace: ws),
      );
      await tool.execute(ToolCall(
        id: 't2',
        name: 'append_knowledge',
        argumentsJson: '{"content":"${'y' * 400}"}',
      ));
      final saved =
          await HermesKnowledgeStore(workspace: ws).loadAll();
      expect(saved.single.content.length, 301); // 300 + ellipsis
    });

    test('missing content throws', () async {
      final tool = KnowledgeToolRegistry(
        store: HermesKnowledgeStore(workspace: MemoryWorkspace()),
      );
      await expectLater(
        tool.execute(const ToolCall(
          id: 't3',
          name: 'append_knowledge',
          argumentsJson: '{}',
        )),
        throwsA(isA<ToolArgumentsException>()),
      );
    });
  });

  group('Reflection', () {
    test('not triggered under caps', () {
      const reflector = Reflector();
      expect(reflector.shouldReflect(10, 100), isFalse);
      expect(reflector.shouldReflect(31, 100), isTrue);
      expect(reflector.shouldReflect(10, 5000), isTrue);
    });

    test('dedupes exact duplicates and merges frequency', () async {
      final ws = MemoryWorkspace();
      final store = HermesKnowledgeStore(workspace: ws);
      await store.saveAll([
        entry('k-1', 'Always clear the pub cache before CI builds',
            frequency: 2),
        entry('k-2', 'Always clear the pub cache before CI  builds.',
            frequency: 5),
        entry('k-3', 'unrelated note', frequency: 1),
      ]);
      final report = await const Reflector().reflect(store, force: true);
      expect(report, isNotNull);
      expect(report!.entriesBefore, 3);
      expect(report.entriesAfter, 2);
      expect(report.absorbedIds, hasLength(1));
      final kept = await store.loadAll();
      final merged = kept.firstWhere((e) => e.id == 'k-1' || e.id == 'k-2');
      expect(merged.frequency, 7);
    });

    test('folds near-duplicates into one generalized entry', () async {
      final ws = MemoryWorkspace();
      final store = HermesKnowledgeStore(workspace: ws);
      await store.saveAll([
        entry('k-1', 'flutter build apk needs java 17 on this machine',
            category: 'pattern'),
        entry('k-2', 'flutter build apk requires java 17 on this machine',
            category: 'pattern'),
      ]);
      final report = await const Reflector().reflect(store, force: true);
      expect(report!.generalizedGroups, 1);
      final kept = await store.loadAll();
      expect(kept, hasLength(1));
      expect(kept.single.source, 'reflection');
      expect(kept.single.frequency, 0);
    });
  });

  group('Forgetting', () {
    final now = DateTime(2026, 9, 1);

    test('vitality buckets by age and frequency', () {
      const policy = ForgettingPolicy();
      expect(
        policy.vitalityOf(
          entry('a', 'x',
              lastTriggeredAt: now.subtract(const Duration(days: 1))),
          now,
        ),
        KnowledgeVitality.active,
      );
      expect(
        policy.vitalityOf(
          entry('b', 'x',
              lastTriggeredAt: now.subtract(const Duration(days: 15))),
          now,
        ),
        KnowledgeVitality.cooling,
      );
      expect(
        policy.vitalityOf(
          entry('c', 'x',
              lastTriggeredAt: now.subtract(const Duration(days: 60))),
          now,
        ),
        KnowledgeVitality.expired,
      );
      // frequency floor protects old entries
      expect(
        policy.vitalityOf(
          entry('d', 'x',
              lastTriggeredAt: now.subtract(const Duration(days: 60)),
              frequency: 5),
          now,
        ),
        KnowledgeVitality.active,
      );
    });

    test('drops expired first, then trims to token budget hottest-first',
        () async {
      final old = entry('old', 'stale entry',
          lastTriggeredAt: now.subtract(const Duration(days: 90)));
      final hot = entry('hot', 'fresh and useful',
          lastTriggeredAt: now.subtract(const Duration(days: 1)));
      final mid = entry('mid', 'somewhat recent',
          lastTriggeredAt: now.subtract(const Duration(days: 3)));
      final report = forget(
        [old, hot, mid],
        policy: const ForgettingPolicy(maxLedgerTokens: 10),
        now: now,
      );
      expect(report.droppedIds, contains('old'));
      expect(report.droppedIds.contains('hot'), isFalse);
      expect(report.kept.first.id, 'hot');
    });

    test('store.applyForgetting persists the prune', () async {
      final ws = MemoryWorkspace();
      final store = HermesKnowledgeStore(workspace: ws);
      await store.saveAll([
        entry('gone', 'ancient knowledge',
            lastTriggeredAt: DateTime.now().subtract(const Duration(days: 400))),
        entry('stay', 'current knowledge'),
      ]);
      await store.applyForgetting();
      final kept = await store.loadAll();
      expect(kept.map((e) => e.id), ['stay']);
    });
  });

  group('HermesMemory end-to-end', () {
    test('recall surfaces stored lessons as strings', () async {
      final memory = HermesMemory(
        store: HermesKnowledgeStore(workspace: MemoryWorkspace({
          '.shelly/knowledge.jsonl':
              '{"id":"k-1","content":"run doctor before upgrade","frequency":0}\n',
        })),
        autoCapture: false,
      );
      expect(await memory.recall('should I run doctor before upgrade?'),
          ['run doctor before upgrade']);
    });

    test('maybeRemember appends a lesson then upkeep keeps ledger sane',
        () async {
      final ws = MemoryWorkspace();
      final memory = HermesMemory(
        store: HermesKnowledgeStore(workspace: ws),
      );
      await memory.maybeRemember(
        'The build failed because the Gradle daemon was stale. '
        'Killing the daemon and rerunning fixed it.',
        _checkpoint(),
      );
      final entries = await HermesKnowledgeStore(workspace: ws).loadAll();
      expect(entries, hasLength(1));
      expect(entries.single.source, 'agent');
      expect(entries.single.category, 'lesson');
    });

    test('short replies are not captured', () async {
      final ws = MemoryWorkspace();
      final memory = HermesMemory(
        store: HermesKnowledgeStore(workspace: ws),
      );
      await memory.maybeRemember('OK done.', _checkpoint());
      expect(await HermesKnowledgeStore(workspace: ws).loadAll(), isEmpty);
    });
  });
}

AgentCheckpoint _checkpoint() => const AgentCheckpoint(
      messages: [],
      round: 1,
      consumedTokens: 0,
      toolCalls: 0,
      pendingToolCalls: [],
    );
