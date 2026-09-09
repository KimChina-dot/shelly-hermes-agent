// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../../core/agent_core.dart';
import '../../core/models.dart';

import 'intent_router.dart';

/// Turns a user request into a short ordered step list with ONE model call
/// (PHASE 3). The step shape matches the `plan` tool's `steps` array
/// (concise strings the recitation block renders as a numbered list), so a
/// plan can be fed straight into the notes-tool registry state by the
/// integration layer.
///
/// The gateway is the same [ModelGateway] type the summarizers use; tests
/// inject a scripted one. Each call is an additional prefill against the
/// agent's token budget (see [Brain]), so the prompt stays small and the
/// reply is just the step lines.
///
/// Planning is strictly best-effort: every failure mode — gateway errors,
/// unparseable output, empty replies — resolves to an empty list and never
/// throws. An empty plan simply means "no plan", not an error.
class Planner {
  Planner({required ModelGateway gateway}) : _gateway = gateway;

  final ModelGateway _gateway;

  /// The prompt asks for at most this many steps.
  static const int maxSteps = 8;

  /// Steps longer than this are not "concise" and are dropped.
  static const int maxStepChars = 200;

  /// Input cap keeps a huge request from ballooning the call.
  static const int maxInputChars = 4000;

  static const _systemPrompt =
      '你是任务规划器。把用户的请求拆成 3 到 8 条简短的执行步骤,按顺序执行。'
      '只输出步骤列表,每行一条,用 1. 2. 3. 这样的编号开头。'
      '不要输出解释、注释或代码块以外的内容。';

  /// Asks the model for an ordered plan for [userText]. Returns 0-[maxSteps]
  /// concise strings; never throws.
  Future<List<String>> planFor(String userText) async {
    final trimmed = userText.trim();
    if (trimmed.isEmpty) return const [];
    try {
      final reply = await _gateway.complete([
        const AgentMessage(role: MessageRole.system, content: _systemPrompt),
        AgentMessage(role: MessageRole.user, content: _clip(trimmed)),
      ]);
      return parsePlan(reply.content);
    } catch (_) {
      // A broken gateway or a bad payload must never break the chat.
      return const [];
    }
  }

  /// Parses the model reply into steps. The reply's own lines and the lines
  /// of each fenced ``` block are both considered. Numbered (`1.` `1、`
  /// `(1)`) or bulleted (`-` `*` `·`) lines are the explicit plan signal:
  /// when any of them is present, surrounding prose lines are dropped.
  /// Otherwise bare plain lines are accepted only when at least two of them
  /// remain, so a single prose sentence never becomes a one-step "plan".
  /// Fence markers, blank lines and overly long entries never become steps.
  /// Anything else yields an empty list.
  List<String> parsePlan(String raw) {
    final candidates = <String>[
      raw.trim(),
      for (final match
          in RegExp(r'```(?:\w+)?\s*([\s\S]*?)```').allMatches(raw))
        match.group(1) ?? '',
    ];
    for (final candidate in candidates) {
      final steps = _stepsFromLines(candidate.split(RegExp(r'\r?\n')));
      if (steps.isNotEmpty) return steps;
    }
    return const [];
  }

  /// Leading list prefix of a plan line: `(1)` / `1.` / `1、` / `1)` /
  /// fullwidth variants, or a `-`/`*`/`·` bullet followed by whitespace.
  final RegExp _listPrefix =
      RegExp(r'^\s*(?:\(\d{1,2}\)\s*|\d{1,2}[.、)）．:：]\s*|[-*·]\s+)');

  List<String> _stepsFromLines(List<String> lines) {
    final numbered = <String>[];
    final plain = <String>[];
    for (final line in lines) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('```')) continue;
      final prefix = _listPrefix.firstMatch(text);
      final step = prefix == null ? text : text.substring(prefix.end).trim();
      if (!_usable(step)) continue;
      (prefix == null ? plain : numbered).add(step);
      if (numbered.length >= maxSteps) break;
    }
    final steps = numbered.isNotEmpty ? numbered : plain;
    if (steps.length < 2 && numbered.isEmpty) return const [];
    return steps.take(maxSteps).toList(growable: false);
  }

  bool _usable(String step) => step.isNotEmpty && step.length <= maxStepChars;

  String _clip(String text) => text.length > maxInputChars
      ? text.substring(0, maxInputChars)
      : text;
}

/// The outcome of one [Brain.decide] round.
class BrainDecision {
  const BrainDecision({required this.kind, this.steps = const []});

  /// Routed intent; [IntentKind.quickAnswer] means "answer directly".
  final IntentKind kind;

  /// Ordered plan steps; empty for quick answers and for multi-step
  /// requests whose planning failed (fail-open, see [Planner]).
  final List<String> steps;
}

/// Thin facade wiring [IntentRouter] + [Planner] behind one entry point
/// (PHASE 3): [decide] routes the request first; only multiStep intents pay
/// for a planning call, single-step intents bypass the planner entirely
/// with zero overhead.
///
/// BUDGET NOTE: Brain model calls are NOT free rounds — they are one
/// additional prefill each, on top of the task's normal agent rounds, and
/// they MUST count against the agent's 64K token budget
/// (`AgentLimits.maxTokens`). The integration layer is expected to hand the
/// Brain a budget-aware [ModelGateway] whose replies are charged to the
/// same `consumedTokens` counter as a regular round; this class performs no
/// accounting of its own.
class Brain {
  Brain({required ModelGateway gateway})
      : _router = IntentRouter(gateway: gateway),
        _planner = Planner(gateway: gateway);

  final IntentRouter _router;
  final Planner _planner;

  /// Classifies [userText] and, for multi-step intents, asks for a plan.
  /// Never throws: router failures degrade to quickAnswer, planner
  /// failures to an empty step list.
  Future<BrainDecision> decide(String userText) async {
    final kind = await _router.classify(userText);
    if (kind != IntentKind.multiStep) {
      return BrainDecision(kind: kind);
    }
    return BrainDecision(
      kind: kind,
      steps: await _planner.planFor(userText),
    );
  }

  /// Direct access to the router (e.g. for UI hints without planning).
  Future<IntentKind> classify(String userText) => _router.classify(userText);

  /// Direct access to the planner (e.g. re-planning an updated request).
  Future<List<String>> planFor(String userText) => _planner.planFor(userText);
}
