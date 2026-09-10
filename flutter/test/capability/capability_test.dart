import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/capability/registry/capability.dart';
import 'package:shelly_hermes/capability/registry/capability_registry.dart';
import 'package:shelly_hermes/capability/registry/capability_router.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

Capability _cap(
  String id, {
  String name = '测试能力',
  String description = '测试描述',
  CapabilityCategory category = CapabilityCategory.search,
  CapabilityRiskLevel risk = CapabilityRiskLevel.l0Read,
  List<ToolSpec> tools = const [],
  TrustScore? trust,
}) =>
    Capability(
      id: id,
      name: name,
      description: description,
      category: category,
      riskLevel: risk,
      tools: tools,
      trust: trust,
    );

void main() {
  group('CapabilityRegistry', () {
    test('register + byId + all, idempotent by id', () {
      final registry = CapabilityRegistry();
      registry.register(_cap('a'));
      registry.register(_cap('a', name: '替换版'));
      registry.register(_cap('b'));

      expect(registry.length, 2);
      expect(registry.byId('a')?.name, '替换版');
      expect(registry.all().map((c) => c.id).toSet(), {'a', 'b'});
    });

    test('byCategory filters', () {
      final registry = CapabilityRegistry();
      registry.register(_cap('a', category: CapabilityCategory.search));
      registry.register(_cap('b', category: CapabilityCategory.terminal));
      registry.register(_cap('c', category: CapabilityCategory.search));

      expect(registry.byCategory(CapabilityCategory.search).map((c) => c.id),
          ['a', 'c']);
      expect(registry.byCategory(CapabilityCategory.mcp), isEmpty);
    });

    test('fromRegistry wraps an AgentToolRegistry specs into a Capability',
        () {
      final registry = CapabilityRegistry();
      final capability = CapabilityRegistry.fromRegistry(
        id: 'workspace',
        name: '工作区文件',
        description: '读取和写入工作区文件',
        category: CapabilityCategory.filesystem,
        riskLevel: CapabilityRiskLevel.l1LocalWrite,
        registry: WorkspaceToolRegistry(workspace: _FakeWorkspace()),
      );

      registry.register(capability);
      expect(registry.byId('workspace')!.tools.map((t) => t.name),
          containsAll(['read_file', 'write_file']));
    });
  });

  group('CapabilityRouter scoring', () {
    final router = const CapabilityRouter();
    final registry = CapabilityRegistry();
    registry.register(_cap(
      '文件搜索',
      name: '文件搜索',
      description: '按名称或内容搜索工作区文件',
      tools: const [
        ToolSpec('search_files', '搜索工作区文件', 'low'),
      ],
    ));
    registry.register(_cap(
      '终端命令',
      name: '终端命令',
      description: '在工作区执行 shell 命令',
      category: CapabilityCategory.terminal,
      risk: CapabilityRiskLevel.l2Execute,
      tools: const [
        ToolSpec('run_command', '执行 shell 命令', 'high'),
      ],
    ));

    test('higher relevance wins', () {
      final ranked = router.rank(registry, taskHint: '搜索文件内容');
      expect(ranked.first.capability.id, '文件搜索');
    });

    test('risk penalty can flip the order', () {
      // 任务与两个能力的重合度都低时,低风险者胜出。
      final ranked = router.rank(registry, taskHint: '完全不相关的任务词');
      expect(ranked.first.capability.id, '文件搜索');
    });

    test('trust bonus lifts an otherwise-tied capability', () {
      final trusted = CapabilityRegistry();
      trusted.register(_cap('plain'));
      trusted.register(_cap(
        'proven',
        trust: const TrustScore(uses: 10, successes: 10),
      ));
      final ranked = const CapabilityRouter().rank(trusted, taskHint: '任意');
      expect(ranked.first.capability.id, 'proven');
    });

    test('score clamps to 0-1', () {
      final cap = _cap('x',
          risk: CapabilityRiskLevel.l4ExternalSensitive,
          trust: const TrustScore(uses: 5, successes: 0, failures: 5));
      final score = router.score(cap, taskHint: '无重合词');
      expect(score, inInclusiveRange(0.0, 1.0));
    });

    test('empty registry ranks to empty', () {
      expect(const CapabilityRouter().rank(CapabilityRegistry(), taskHint: 'x'),
          isEmpty);
    });

    test('unknown category returns empty', () {
      final registry = CapabilityRegistry();
      registry.register(_cap('a', category: CapabilityCategory.search));
      expect(registry.byCategory(CapabilityCategory.platform), isEmpty);
    });
  });
}

/// Minimal fake workspace: WorkspaceToolRegistry only reads specs from the
/// concrete class — a no-op implementation is enough for spec inspection.
class _FakeWorkspace implements Workspace {
  @override
  Future<bool> deleteFile(String path) async => false;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<String?> readFile(String path) async => null;

  @override
  Future<List<String>> listFiles([String prefix = '']) async => [];

  @override
  Future<List<String>> searchFiles(String query) async => [];

  @override
  Future<void> writeFile(String path, String content) async {}
}
