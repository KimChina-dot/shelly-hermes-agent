// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../../core/agent_core.dart';
import '../../core/models.dart';

/// How the Brain routes one user request (PHASE 3).
enum IntentKind { quickAnswer, multiStep }

/// Classifies a user request into an [IntentKind] with ONE short model call.
///
/// The gateway is the same [ModelGateway] type the summarizers and the
/// memory extractor use; tests inject a scripted one. Because every Brain
/// model call is an additional prefill against the agent's token budget
/// (see the Brain facade in `planner.dart`), the router prompt is
/// deliberately tiny and the reply is a single strict label.
///
/// Classification is strictly best-effort and fail-open: every failure mode
/// — gateway errors, unparseable or invalid labels, empty replies — resolves
/// to [IntentKind.quickAnswer], the zero-cost default that skips the
/// planner and answers directly. A wrong "quick answer" verdict costs
/// nothing; forcing the multi-step path would spend a planning prefill, so
/// ambiguity must always fall toward quickAnswer.
class IntentRouter {
  IntentRouter({required ModelGateway gateway}) : _gateway = gateway;

  final ModelGateway _gateway;

  static const _systemPrompt =
      '你是意图分类器。判断用户请求是「直接回答」还是「多步骤任务」。'
      '只输出一个标签:quickAnswer 或 multiStep。'
      '不要输出解释、标点或代码块以外的内容。';

  /// Asks the model for the intent label of [userText]. Never throws.
  Future<IntentKind> classify(String userText) async {
    final trimmed = userText.trim();
    if (trimmed.isEmpty) return IntentKind.quickAnswer;
    try {
      final reply = await _gateway.complete([
        const AgentMessage(role: MessageRole.system, content: _systemPrompt),
        AgentMessage(role: MessageRole.user, content: trimmed),
      ]);
      return parseKind(reply.content);
    } catch (_) {
      // A broken gateway or a bad payload must never break the chat.
      return IntentKind.quickAnswer;
    }
  }

  /// Parses the model reply into a label. Accepted shapes: the bare label
  /// (any casing/whitespace), a fenced code block, or the label wrapped in
  /// surrounding prose. Anything else yields [IntentKind.quickAnswer].
  IntentKind parseKind(String raw) {
    final candidates = <String>[
      raw.trim(),
      for (final match
          in RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').allMatches(raw))
        match.group(1) ?? '',
    ];
    for (final candidate in candidates) {
      final match = RegExp(r'quickAnswer|multiStep', caseSensitive: false)
          .firstMatch(candidate);
      if (match == null) continue;
      return match.group(0)!.toLowerCase() == 'multistep'
          ? IntentKind.multiStep
          : IntentKind.quickAnswer;
    }
    return IntentKind.quickAnswer;
  }
}
