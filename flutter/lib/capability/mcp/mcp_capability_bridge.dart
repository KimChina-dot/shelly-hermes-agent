import '../registry/capability.dart';
import '../registry/capability_registry.dart';
import '../../core/mcp/mcp_tool_registry.dart';

/// PHASE 7 (v3.0 §25): MCP 服务器统一进 Capability 层的桥接。
///
/// 每个可达的 MCP 服务器 = 一个 Capability(category: mcp, L4 外部敏感级
/// ——远程内容天然不可信),工具透传;不可达的服务器被跳过(与
/// McpToolRegistry.connect 的 best-effort 语义一致)。
class McpCapabilityBridge {
  McpCapabilityBridge();

  /// 把 MCP 注册表中的每个服务器映射为一个 Capability 注册进 [registry]。
  /// 服务器 id = `mcp_<serverId>`(与 DSH 的 `dsh_` 前缀约定平行)。
  /// 返回本批注册的 id 列表,并自动移除上一批中已消失的服务器。
  List<String> syncInto(
    CapabilityRegistry registry,
    McpToolRegistry mcpRegistry, {
    Map<String, TrustScore>? trustScores,
  }) {
    final registeredIds = <String>[];
    try {
      // 移除上一批已消失的 MCP capability(服务器被删除或不可达)。
      final stale = [
        for (final c in registry.byCategory(CapabilityCategory.mcp))
          if (!c.id.startsWith('mcp_') ||
              !mcpRegistry.serverIds.contains(_serverIdOf(c.id)))
            c.id,
      ];
      for (final id in stale) {
        registry.remove(id);
      }
      for (final serverId in mcpRegistry.serverIds) {
        final id = 'mcp_$serverId';
        final specs = mcpRegistry.specsFor(serverId);
        if (specs.isEmpty) continue;
        registry.register(
          Capability(
            id: id,
            name: serverId,
            description: 'MCP 服务器 $serverId 提供的远程工具',
            category: CapabilityCategory.mcp,
            riskLevel: CapabilityRiskLevel.l4ExternalSensitive,
            tools: specs,
            trust: trustScores?[serverId],
          ),
        );
        registeredIds.add(id);
      }
    } catch (_) {
      // MCP 不可用:零注入,聊天与能力层不受影响。
    }
    return registeredIds;
  }

  String _serverIdOf(String capabilityId) =>
      capabilityId.substring('mcp_'.length);
}
