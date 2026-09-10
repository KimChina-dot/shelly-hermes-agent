import '../../core/dsh/tool_registry.dart';
import '../../core/mcp/bridge_client.dart';
import '../../core/mcp/mcp_tool_registry.dart';

/// PHASE 17 (v3.0 §23/§60): the real capability availability set behind
/// [SkillToolRegistry.isCapabilityAvailable].
///
/// PHASE 9 shipped the skill tools with an admit-everything placeholder
/// because task assembly had no live capability signal. This builder turns
/// the registries a task run actually assembles into the set of
/// CapabilityRegistry ids (PHASE 4) a skill's `requiredCapabilities` is
/// checked against — same id space the built-in skills reference
/// ('filesystem', 'terminal'):
///
/// | assembly signal                                       | capability id      |
/// |-------------------------------------------------------|--------------------|
/// | [WorkspaceToolRegistry] joins the composite            | 'filesystem'       |
/// | [ShellToolRegistry] joins the composite                | 'terminal'         |
/// | MCP server answered discovery with at least one tool   | `'mcp_<serverId>'` |
/// | bridge config complete and catalog fetched in time     | 'bridge'           |
/// | DSH plugin currently enabled                          | `'<manifest.id>'`  |
///
/// The MCP and DSH id schemes mirror [McpCapabilityBridge] (PHASE 7) and
/// [DynamicSkillHost] (PHASE 6) exactly, so a skill requiring
/// 'mcp_github' or 'dev.test.weather' resolves against the same ids the
/// unified capability layer registers. The bridge contributes one
/// channel-level id: its public surface only exposes the catalog as
/// sanitized `bridge_<server>_<tool>` tool names, so per-server ids are
/// not recoverable — 拿不到的不注册. Everything not actually up
/// contributes nothing: an unreachable MCP server, a timed-out bridge and
/// a disabled DSH plugin all stay out of the set.
Set<String> availableCapabilityIds({
  required bool workspaceRegistered,
  required bool shellRegistered,
  McpToolRegistry? mcpRegistry,
  BridgeToolRegistry? bridgeRegistry,
  DshToolRegistry? dshTools,
}) {
  final ids = <String>{
    if (workspaceRegistered) 'filesystem',
    if (shellRegistered) 'terminal',
  };
  if (mcpRegistry != null) {
    // serverIds only contains servers that yielded entries, but keep the
    // empty-specs skip for exact parity with McpCapabilityBridge.syncInto.
    for (final serverId in mcpRegistry.serverIds) {
      if (mcpRegistry.specsFor(serverId).isNotEmpty) {
        ids.add('mcp_$serverId');
      }
    }
  }
  // A non-null bridge registry means the config was complete AND the
  // catalog loaded within the assembly timeout — the channel is really up.
  if (bridgeRegistry != null) {
    ids.add('bridge');
  }
  if (dshTools != null) {
    try {
      for (final plugin in dshTools.pluginRegistry.listEnabled()) {
        ids.add(plugin.manifest.id);
      }
    } catch (_) {
      // DSH surface unavailable: inject nothing (DynamicSkillHost posture).
    }
  }
  return ids;
}
