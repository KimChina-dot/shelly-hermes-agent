import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/dsh_provider.dart';
import '../../core/dsh/registry.dart';
import '../../core/dsh/tool_registry.dart';
import '../../core/tools/registry.dart' show ToolSpec;
import '../registry/capability.dart';
import '../registry/capability_registry.dart';

/// PHASE 6 (v3.0 §24): DSh 升级为 Dynamic Skill Host 的接入层。
///
/// DSh 早已具备动态加载/卸载/版本/信任能力(见 DshPluginRegistry);本类
/// 把这些动态插件映射为 Capability,让它们与内置工具在统一注册表中平权:
/// - 每个启用的 DSh 插件 = 一个 Capability(category: dsh,L2 执行级风险,
///   信任分来自插件的 trust 状态);
/// - 插件被禁用/卸载时对应的 Capability 从注册表移除;
/// - Agent 不感知底层是 MCP、DSh 还是原生工具——只有 Capability。
///
/// 全部方法 best-effort:DSh 不可用时返回空集,聊天与能力层不受影响。
class DynamicSkillHost {
  DynamicSkillHost({required this.pluginRegistry, required this.dshTools});

  final DshPluginRegistry pluginRegistry;
  final DshToolRegistry dshTools;

  /// 把当前启用的 DSh 插件注册进 [registry]。返回本批注册的 id 列表
  /// (= manifest.id,reverse-DNS 本身全局唯一),供调用方在下一次刷新前
  /// 先移除上一批(防止禁用插件残留)。
  List<String> syncInto(CapabilityRegistry registry) {
    final registeredIds = <String>[];
    try {
      // 先移除上一批已不在 listEnabled() 中的 DSh capability(插件被禁用
      // 或卸载后,对应的 Capability 不应残留)。
      final enabledIds = {
        for (final p in pluginRegistry.listEnabled()) p.manifest.id,
      };
      for (final c in registry.byCategory(CapabilityCategory.dsh)) {
        if (!enabledIds.contains(c.id)) registry.remove(c.id);
      }
      for (final plugin in pluginRegistry.listEnabled()) {
        final id = plugin.manifest.id;
        registry.register(
          Capability(
            id: id,
            name: plugin.manifest.name,
            description: plugin.manifest.description,
            category: CapabilityCategory.dsh,
            riskLevel: CapabilityRiskLevel.l2Execute,
            tools: _toolsFor(dshTools, plugin.manifest.id),
          ),
        );
        registeredIds.add(id);
      }
    } catch (_) {
      // DSh 不可用:不向统一注册表注入任何条目。
    }
    return registeredIds;
  }

  List<ToolSpec> _toolsFor(DshToolRegistry dshTools, String pluginId) {
    return dshTools.specs
        .where((spec) => spec.name.startsWith('${pluginId}_'))
        .toList();
  }
}

/// Provider:与 dshRegistryProvider/dshToolsProvider 同生命周期。
final dynamicSkillHostProvider = Provider<DynamicSkillHost>((ref) {
  return DynamicSkillHost(
    pluginRegistry: ref.watch(dshRegistryProvider),
    dshTools: ref.watch(dshToolsProvider),
  );
});
