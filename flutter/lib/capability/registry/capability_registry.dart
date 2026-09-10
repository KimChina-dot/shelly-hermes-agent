import '../../core/runtime/tool_registry.dart';
import 'capability.dart';

/// Unified capability registry (v3.0 §20): the single place where every
/// capability — built-in tools, MCP, DSh, platform — is registered. The
/// agent routes over Capabilities; the underlying transport (MCP vs native
/// vs DSh) is invisible to it.
class CapabilityRegistry {
  final Map<String, Capability> _byId = {};

  /// Registers (or replaces) a capability. Idempotent by id.
  void register(Capability capability) {
    _byId[capability.id] = capability;
  }

  Capability? byId(String id) => _byId[id];

  /// 移除一个 capability(Dsh 插件禁用/卸载时由 DynamicSkillHost 调用)。
  void remove(String id) => _byId.remove(id);

  List<Capability> byCategory(CapabilityCategory category) =>
      [for (final c in _byId.values) if (c.category == category) c];

  /// Unmodifiable snapshot, registration order preserved.
  List<Capability> all() => List.unmodifiable(_byId.values);

  int get length => _byId.length;

  /// PHASE 4 bridge: wraps an existing [AgentToolRegistry]'s specs into a
  /// Capability so the current registries (workspace, shell, terminal,
  /// memory_search, knowledge, mcp, …) join the unified layer without any
  /// change to them.
  static Capability fromRegistry({
    required String id,
    required String name,
    required String description,
    required CapabilityCategory category,
    required CapabilityRiskLevel riskLevel,
    required AgentToolRegistry registry,
    TrustScore? trust,
  }) {
    return Capability(
      id: id,
      name: name,
      description: description,
      category: category,
      riskLevel: riskLevel,
      tools: registry.specs,
      trust: trust,
    );
  }
}
