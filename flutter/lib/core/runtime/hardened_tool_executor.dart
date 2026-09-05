import '../models.dart' show ToolCall;
import '../tools/registry.dart' show ToolError, ToolSpec;
import 'tool_registry.dart' show AgentToolRegistry;

/// Last line of defense around every tool execution: a wall-clock timeout
/// so a wedged tool can never stall the agent loop, and a hard cap on the
/// result string fed back into the model context. Oversized results keep
/// their head and tail (both ends usually matter) and — when a
/// [summarizer] is wired — gain a model digest of the full text, so the
/// model loses less than plain truncation.
class HardenedToolExecutor implements AgentToolRegistry {
  HardenedToolExecutor({
    required this.registry,
    this.timeout = const Duration(seconds: 120),
    this.maxResultChars = 20000,
    this.summarizer,
  });

  final AgentToolRegistry registry;
  final Duration timeout;
  final int maxResultChars;

  /// Optional model digest for oversized results; failures fall back to
  /// plain head+tail truncation.
  final Future<String> Function(String oversizedResult)? summarizer;

  static const _headChars = 12000;
  static const _tailChars = 4000;
  static const _maxSummaryChars = 2000;

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
    return _shrink(result);
  }

  Future<String> _shrink(String result) async {
    final dropped = result.length - _headChars - _tailChars;
    final frame = '${result.substring(0, _headChars)}\n'
        '…(中间 $dropped 字符已省略)…\n'
        '${result.substring(result.length - _tailChars)}';
    final summarize = summarizer;
    if (summarize == null) {
      return '$frame\n…(结果过长,已截断)';
    }
    try {
      final summary =
          await summarize(result).timeout(const Duration(seconds: 20));
      final trimmed = summary.trim();
      if (trimmed.isEmpty) return '$frame\n…(结果过长,已截断)';
      final capped = trimmed.length > _maxSummaryChars
          ? trimmed.substring(0, _maxSummaryChars)
          : trimmed;
      return '（超长结果,模型摘要如下）\n$capped\n\n（原文首尾）\n$frame';
    } catch (_) {
      return '$frame\n…(结果过长,已截断)';
    }
  }
}
