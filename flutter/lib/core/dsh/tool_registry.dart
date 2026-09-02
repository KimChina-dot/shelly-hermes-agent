import '../models.dart';
import '../runtime/tool_registry.dart';
import '../tools/registry.dart';
import '../tools/workspace.dart';
import 'plugin.dart';
import 'registry.dart';

/// Trust levels for plugin tools (PHASE 14):
/// - unknown tool name → blocked (never runs, model sees the denial)
/// - known but not yet trusted → ask (goes through user approval)
/// - trusted (user chose allow-always) → allowed without another prompt
enum DshTrust { blocked, ask, allowed }

/// Per-plugin-tool trust store. Unknown tools are blocked; the UI (or
/// tests) grant trust as decisions are made.
class DshTrustPolicy {
  final Map<String, DshTrust> _trust = {};

  /// Default posture for a tool with no recorded decision.
  DshTrust trustFor(String toolName) => _trust[toolName] ?? DshTrust.blocked;

  /// First contact: a tool that has never been decided starts at ask.
  void markNew(String toolName) {
    _trust.putIfAbsent(toolName, () => DshTrust.ask);
  }

  void setTrust(String toolName, DshTrust trust) =>
      _trust[toolName] = trust;

  Map<String, DshTrust> snapshot() => Map.of(_trust);
}

/// The DSH→Agent tool channel (PHASE 14 registration chain
/// Plugin → DshPluginRegistry → DshToolRegistry → Agent): exposes enabled
/// plugins' tools through the [AgentToolRegistry] seam, gated by the trust
/// policy. Core tools always win on name collisions (dispatch order in
/// CompositeToolRegistry); this registry never accepts a core name anyway
/// because registration rejects collisions.
class DshToolRegistry implements AgentToolRegistry {
  DshToolRegistry({
    required this.pluginRegistry,
    required this.trustPolicy,
  });

  final DshPluginRegistry pluginRegistry;
  final DshTrustPolicy trustPolicy;

  @override
  List<ToolSpec> get specs => [
        for (final plugin in pluginRegistry.listEnabled())
          for (final tool in plugin.tools)
            ToolSpec(tool.decl.name, tool.decl.description, tool.decl.risk),
      ];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        for (final spec in specs)
          {
            'type': 'function',
            'function': {
              'name': spec.name,
              'description': spec.description,
              'parameters': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    final plugin = _ownerOf(call.name);
    if (plugin == null) {
      return 'Error: unknown plugin tool "${call.name}" (blocked by policy)';
    }
    trustPolicy.markNew(call.name);
    switch (trustPolicy.trustFor(call.name)) {
      case DshTrust.blocked:
        return 'Error: plugin tool "${call.name}" blocked by trust policy';
      case DshTrust.ask:
        // The approval gateway upstream already asked the user; reaching
        // here with ask means approval was granted for this call.
        break;
      case DshTrust.allowed:
        break;
    }
    final tool = plugin.tools.firstWhere((t) => t.decl.name == call.name);
    try {
      return await tool.call(decodeArguments(call.argumentsJson));
    } on ToolArgumentsException {
      rethrow;
    } catch (error) {
      return 'Error: plugin tool "${call.name}" failed: $error';
    }
  }

  DshPlugin? _ownerOf(String toolName) {
    for (final plugin in pluginRegistry.listEnabled()) {
      if (plugin.tools.any((t) => t.decl.name == toolName)) return plugin;
    }
    return null;
  }
}
