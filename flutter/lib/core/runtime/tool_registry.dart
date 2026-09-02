import '../agent_core.dart';
import '../models.dart';
import '../tools/registry.dart';

/// Registry seam between the engine and tool providers (core workspace
/// tools today, DSH plugins later). AgentCore only ever sees a
/// [ToolExecutor]; providers are reached through this interface, so plugin
/// tools need no core changes.
abstract interface class AgentToolRegistry implements ToolExecutor {
  /// All tool specs exposed by this registry (merged, deduplicated by name).
  List<ToolSpec> get specs;

  /// OpenAI function-calling definitions for the exposed tools.
  List<Map<String, dynamic>> openAiToolsJson();
}

/// Merges several registries behind one executor. Dispatch goes to the
/// first child that declares the tool name, so core tools win over plugin
/// tools on collision — plugins must not silently shadow the platform.
class CompositeToolRegistry implements AgentToolRegistry {
  CompositeToolRegistry(this._children);

  final List<AgentToolRegistry> _children;

  @override
  List<ToolSpec> get specs => [
        for (final child in _children) ...child.specs,
      ];

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        for (final child in _children) ...child.openAiToolsJson(),
      ];

  @override
  Future<String> execute(ToolCall call) async {
    for (final child in _children) {
      if (child.specs.any((spec) => spec.name == call.name)) {
        return child.execute(call);
      }
    }
    throw ToolError('unknown tool: ${call.name}');
  }
}
