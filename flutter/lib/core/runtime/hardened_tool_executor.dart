import '../models.dart' show ToolCall;
import '../tools/registry.dart' show ToolError, ToolSpec;
import 'tool_registry.dart' show AgentToolRegistry;

/// Last line of defense around every tool execution: a wall-clock timeout
/// so a wedged tool can never stall the agent loop, and a hard cap on the
/// result string fed back into the model context. Shell-level limits live
/// in [ShellExecutor]; this wrapper covers every registry uniformly.
class HardenedToolExecutor implements AgentToolRegistry {
  HardenedToolExecutor({
    required this.registry,
    this.timeout = const Duration(seconds: 120),
    this.maxResultChars = 20000,
  });

  final AgentToolRegistry registry;
  final Duration timeout;
  final int maxResultChars;

  @override
  List<ToolSpec> get specs => registry.specs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() =>
      registry.openAiToolsJson();

  @override
  Future<String> execute(ToolCall call) async {
    String result;
    try {
      result = await registry.execute(call).timeout(timeout, onTimeout: () {
        throw ToolError('工具执行超时(>${timeout.inSeconds}s),已中止');
      });
    } on ToolError {
      rethrow;
    }
    if (result.length <= maxResultChars) return result;
    return '${result.substring(0, maxResultChars)}\n'
        '…(结果过长,已截断 ${result.length - maxResultChars} 字符)';
  }
}
