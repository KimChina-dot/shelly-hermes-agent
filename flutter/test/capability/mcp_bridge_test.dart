import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/capability/mcp/mcp_capability_bridge.dart';
import 'package:shelly_hermes/capability/registry/capability.dart';
import 'package:shelly_hermes/capability/registry/capability_registry.dart';
import 'package:shelly_hermes/core/mcp/mcp_client.dart';
import 'package:shelly_hermes/core/mcp/mcp_tool_registry.dart';

void main() {
  test('syncInto registers one capability per reachable server', () {
    final registry = CapabilityRegistry();
    final mcpRegistry = McpToolRegistry(tools: const [
      McpToolEntry(
        server: McpServerConfig(id: 'github', name: 'GitHub', url: 'u1'),
        info: McpToolInfo(name: 'search', description: '搜索仓库'),
      ),
      McpToolEntry(
        server: McpServerConfig(id: 'db', name: 'DB', url: 'u2'),
        info: McpToolInfo(name: 'query', description: '执行查询'),
      ),
    ]);

    final bridge = McpCapabilityBridge();
    final ids = bridge.syncInto(registry, mcpRegistry);

    expect(ids, containsAll(['mcp_github', 'mcp_db']));
    final github = registry.byId('mcp_github')!;
    expect(github.category, CapabilityCategory.mcp);
    expect(github.riskLevel, CapabilityRiskLevel.l4ExternalSensitive);
    expect(github.tools.map((t) => t.name), contains('mcp_GitHub_search'));
  });

  test('re-sync removes servers that disappeared', () {
    final registry = CapabilityRegistry();
    final bridge = McpCapabilityBridge();
    var mcpRegistry = McpToolRegistry(tools: const [
      McpToolEntry(
        server: McpServerConfig(id: 'github', name: 'GitHub', url: 'u1'),
        info: McpToolInfo(name: 'search', description: '搜索'),
      ),
    ]);
    bridge.syncInto(registry, mcpRegistry);
    expect(registry.byId('mcp_github'), isNotNull);

    // 服务器被移除:只剩另一个服务器。
    mcpRegistry = McpToolRegistry(tools: const [
      McpToolEntry(
        server: McpServerConfig(id: 'db', name: 'DB', url: 'u2'),
        info: McpToolInfo(name: 'query', description: '查询'),
      ),
    ]);
    bridge.syncInto(registry, mcpRegistry);

    expect(registry.byId('mcp_github'), isNull);
    expect(registry.byId('mcp_db'), isNotNull);
  });

  test('trust scores attach to the capability', () {
    final registry = CapabilityRegistry();
    final mcpRegistry = McpToolRegistry(tools: const [
      McpToolEntry(
        server: McpServerConfig(id: 'github', name: 'GitHub', url: 'u1'),
        info: McpToolInfo(name: 'search', description: '搜索'),
      ),
    ]);
    final bridge = McpCapabilityBridge();
    bridge.syncInto(
      registry,
      mcpRegistry,
      trustScores: {
        'github': const TrustScore(uses: 10, successes: 9),
      },
    );

    expect(registry.byId('mcp_github')!.trust?.successRate, closeTo(0.9, 0.001));
  });

  test('all servers unreachable → empty, registry untouched', () {
    final registry = CapabilityRegistry();
    final bridge = McpCapabilityBridge();
    final ids = bridge.syncInto(
      registry,
      McpToolRegistry(tools: const []),
    );
    expect(ids, isEmpty);
    expect(registry.length, 0);
  });
}
