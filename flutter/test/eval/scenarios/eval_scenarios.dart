/// PHASE 46 — trajectory-level eval scenarios for the real AgentCore loop.
///
/// Each scenario is a deterministic regression case in the Anthropic evals
/// sense: it grades *what the agent produced* — the workspace outcome after
/// the run and the trajectory it took (tools used, order, rounds) — never
/// the exact textual path. Rubric checks are plain Dart predicates, so the
/// suite needs no LLM judge and is fully reproducible.
///
/// PHASE 11 adds the Brain-path scenarios (11-15): a scenario may replay a
/// Brain preflight ([BrainScript]) through the same scripted transport the
/// engine rounds use, composed exactly like `chat_session.dart` wires it in
/// production — [MeteredGateway] accounting, plan seeding into the notes
/// registry, and the preflight charge carried into the engine's one token
/// budget via `AgentCore.initialConsumedTokens`.
///
/// The harness in [runScenario] drives the real [AgentCore] with:
/// - a scripted [StreamingModelGateway] (replies queued up front),
/// - a [MemoryWorkspace] seeded by the scenario,
/// - the REAL [WorkspaceToolRegistry] and [ShellToolRegistry] (policy and
///   risk classification included),
/// - a shell [ProcessRunner] that refuses to execute (evals must never spawn
///   real processes; policy-blocked and unsupported paths still work).
library;

import 'dart:convert';

import 'package:shelly_hermes/agent/brain/brain_gateway.dart';
import 'package:shelly_hermes/agent/brain/intent_router.dart' show IntentKind;
import 'package:shelly_hermes/agent/brain/planner.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/gateway/openai_messages.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/notes_tool.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/state/chat_session.dart'
    show
        personaWithRecitation,
        personaWithToolRules,
        recitationBodyDecorator,
        systemPromptWithMemory;

// ---------------------------------------------------------------------------
// Scenario + rubric model
// ---------------------------------------------------------------------------

/// One deterministic rubric check. [name] is what the PASS/FAIL report shows.
class RubricCheck {
  const RubricCheck(this.name, this.predicate);

  final String name;
  final bool Function(EvalRunEvidence evidence) predicate;
}

/// Everything an outcome/trajectory check may consult after a run.
class EvalRunEvidence {
  EvalRunEvidence({
    required this.result,
    required this.runError,
    required this.workspace,
    required this.toolCallOrder,
    required this.toolResults,
    required this.failedToolCalls,
    required this.modelRounds,
    required this.systemPromptsSeen,
    required this.approvalRequests,
    required this.shellCommands,
    required this.checkpointsSaved,
    required this.gatewayCalls,
    required this.preflightTokens,
    required this.engineRequests,
  });

  /// Terminal [AgentResult]; null when the run threw out of [AgentCore].
  final AgentResult? result;

  /// Non-null when the harness itself failed (e.g. scripted replies ran out).
  final String? runError;

  /// Post-run workspace state (outcome grading).
  final MemoryWorkspace workspace;

  /// Tool names in execution order (trajectory grading).
  final List<String> toolCallOrder;

  /// Tool name → returned result strings, in call order.
  final Map<String, List<String>> toolResults;

  /// Tool calls whose execution threw (ToolFinished.succeeded == false).
  final List<String> failedToolCalls;

  /// Number of engine rounds actually consumed (AgentCore model calls only,
  /// Brain preflight calls excluded).
  final int modelRounds;

  /// System-role message content the model saw at round start (memory /
  /// persona composition grading); engine requests only, so a Brain
  /// preflight's router/planner prompts never pollute the check.
  final List<String> systemPromptsSeen;

  /// Tool names that were routed through the approval gateway.
  final List<String> approvalRequests;

  /// Commands that reached the shell runner (must stay empty in evals).
  final List<String> shellCommands;

  final int checkpointsSaved;

  /// Every model-gateway call the run made — Brain preflight (classify,
  /// plan, failed calls included) plus engine rounds. The exact count pins
  /// down "the planner was never called" (PHASE 11 bypass shape).
  final int gatewayCalls;

  /// Tokens the Brain preflight charged through [MeteredGateway], handed to
  /// the engine as `AgentCore.initialConsumedTokens` (PHASE 8 seam).
  final int preflightTokens;

  /// What the engine-facing gateway saw per round, after the production
  /// recitation decoration: one message list per engine round, in order.
  final List<List<AgentMessage>> engineRequests;

  /// Final assistant message when the run completed, else null.
  String? get finalAnswer =>
      result is AgentCompleted ? (result as AgentCompleted).message : null;
}

/// Scripted Brain preflight (PHASE 11): [classify] is the reply the intent
/// classify call receives; [plan] (only for a `multiStep` verdict) is the
/// reply the planning call receives. The `BrainScript.failing` constructor
/// makes the classify call throw before any reply is delivered — the
/// fail-open shape of a broken classifier.
///
/// The replies replay through the SAME scripted transport the engine rounds
/// use, ordered classify → plan → engine rounds, mirroring how production
/// routes Brain calls through the main gateway as extra prefills.
class BrainScript {
  const BrainScript({required this.classify, this.plan})
      : classifyThrows = false;

  const BrainScript.failing()
      : classify = null,
        plan = null,
        classifyThrows = true;

  final ModelReply? classify;
  final ModelReply? plan;
  final bool classifyThrows;
}

/// A single eval case: user task + scripted gateway replies + seeded
/// workspace + deterministic rubric.
class EvalScenario {
  const EvalScenario({
    required this.name,
    required this.description,
    required this.userTask,
    required this.script,
    required this.rubric,
    this.seedFiles = const {},
    this.limits = const AgentLimits(maxRounds: 10, maxToolCalls: 16),
    this.persona = '',
    this.memories = const [],
    this.systemPrompt,
    this.composeMemoryPrompt = false,
    this.brain,
    this.withNotesTools = false,
  });

  final String name;
  final String description;
  final String userTask;

  /// Scripted model replies: tool-call rounds first, final answer last.
  /// With a [brain] preflight these are the ENGINE replies only — the
  /// preflight replies live in the [BrainScript].
  final List<ModelReply> script;

  /// Files present in the workspace before the run.
  final Map<String, String> seedFiles;

  /// Deterministic checks graded against [EvalRunEvidence].
  final List<RubricCheck> rubric;

  final AgentLimits limits;

  /// Persona used only with [composeMemoryPrompt].
  final String persona;

  /// Long-term memories used only with [composeMemoryPrompt].
  final List<MemoryFact> memories;

  /// Verbatim system prompt prepended before the user message.
  final String? systemPrompt;

  /// When true the harness composes the system prompt exactly like
  /// chat_session.dart does: systemPromptWithMemory(persona:
  /// personaWithToolRules(persona), memories: memories). The composition
  /// call itself lives in trajectory_test.dart (visibleForTesting seam).
  final bool composeMemoryPrompt;

  /// Brain preflight to run before the engine (PHASE 11). When set, the
  /// harness reproduces the production wiring from chat_session.dart: the
  /// Brain decides through a MeteredGateway over the shared transport, a
  /// multiStep verdict with steps seeds the notes registry plan, and the
  /// charged tokens become `AgentCore.initialConsumedTokens`.
  final BrainScript? brain;

  /// Notes-tool surface without a Brain (PHASE 46 recitation semantics):
  /// adds the plan/note tools and the per-round 「当前计划」 refresh so a
  /// scenario can grade the model keeping its own plan current.
  final bool withNotesTools;
}

/// Aggregated verdict for one scenario, rendered by the harness report.
class ScenarioOutcome {
  const ScenarioOutcome({
    required this.name,
    required this.passed,
    required this.failedChecks,
    required this.modelRounds,
    required this.toolCallCount,
    this.runError,
  });

  final String name;
  final bool passed;
  final List<String> failedChecks;
  final int modelRounds;
  final int toolCallCount;
  final String? runError;
}

// ---------------------------------------------------------------------------
// Rubric check builders
// ---------------------------------------------------------------------------

/// Outcome: the run finished with [AgentCompleted].
RubricCheck completed() => RubricCheck(
      'trajectory: run completed (AgentCompleted)',
      (e) => e.result is AgentCompleted,
    );

/// Outcome: the final assistant message contains [needle].
RubricCheck finalAnswerContains(String needle) => RubricCheck(
      'outcome: final answer contains "$needle"',
      (e) => (e.finalAnswer ?? '').contains(needle),
    );

/// Outcome: file content equals [expected] exactly after the run.
RubricCheck fileEquals(String path, String expected) => RubricCheck(
      'outcome: $path equals expected content',
      (e) => e.workspace.files[path] == expected,
    );

/// Outcome: file exists after the run.
RubricCheck filePresent(String path) => RubricCheck(
      'outcome: $path exists',
      (e) => e.workspace.files.containsKey(path),
    );

/// Outcome: file does not exist after the run.
RubricCheck fileAbsent(String path) => RubricCheck(
      'outcome: $path absent',
      (e) => !e.workspace.files.containsKey(path),
    );

/// Outcome: workspace file map is byte-identical to the seed (nothing was
/// mutated, nothing was added or removed).
RubricCheck workspaceUnchanged(Map<String, String> seed) =>
    RubricCheck('outcome: workspace unchanged after run', (e) {
      final files = e.workspace.files;
      if (files.length != seed.length) return false;
      for (final entry in seed.entries) {
        if (files[entry.key] != entry.value) return false;
      }
      return true;
    });

/// Trajectory: the exact tool sequence executed, in order.
RubricCheck toolSequence(List<String> expected) => RubricCheck(
      'trajectory: tool order == ${expected.join(' -> ')}',
      (e) => _listEquals(e.toolCallOrder, expected),
    );

/// Trajectory: the named tool was used at least once.
RubricCheck usedTool(String name) => RubricCheck(
      'trajectory: used tool $name',
      (e) => e.toolCallOrder.contains(name),
    );

/// Trajectory: none of the named tools were ever called.
RubricCheck noToolNamed(List<String> names) => RubricCheck(
      'trajectory: never uses ${names.join(', ')}',
      (e) => !e.toolCallOrder.any((used) => names.contains(used)),
    );

/// Trajectory: at most [n] model rounds consumed.
RubricCheck modelRoundsAtMost(int n) => RubricCheck(
      'trajectory: <= $n model rounds (actual ${'{rounds}'})',
      (e) => e.modelRounds <= n,
    );

/// Trajectory: at most [n] tool calls executed.
RubricCheck toolCallsAtMost(int n) => RubricCheck(
      'trajectory: <= $n tool calls',
      (e) => e.toolCallOrder.length <= n,
    );

/// Trajectory: no tool execution threw an exception.
RubricCheck noToolFailures() => RubricCheck(
      'trajectory: no tool execution exceptions',
      (e) => e.failedToolCalls.isEmpty,
    );

/// Trajectory: some call of [tool] returned a result containing [needle].
RubricCheck toolResultContains(String tool, String needle) => RubricCheck(
      'trajectory: $tool result contains "$needle"',
      (e) => (e.toolResults[tool] ?? const []).any((r) => r.contains(needle)),
    );

/// Trajectory: the named tool went through the approval gateway.
RubricCheck approvalAskedFor(String tool) => RubricCheck(
      'trajectory: $tool went through approval',
      (e) => e.approvalRequests.contains(tool),
    );

/// Outcome: the shell runner never actually spawned a command.
RubricCheck shellNeverExecuted() => RubricCheck(
      'outcome: no shell command actually executed',
      (e) => e.shellCommands.isEmpty,
    );

/// Trajectory: the system prompt the model saw contains [needle].
RubricCheck systemPromptContains(String needle) => RubricCheck(
      'trajectory: system prompt contains "$needle"',
      (e) =>
          e.systemPromptsSeen.isNotEmpty &&
          e.systemPromptsSeen.first.contains(needle),
    );

/// Trajectory: exactly [n] model-gateway calls in total — Brain preflight
/// (classify/plan, failed calls included) plus engine rounds. Pins down
/// "the planner was never called" and fail-open call shapes.
RubricCheck gatewayCallsExactly(int n) => RubricCheck(
      'trajectory: exactly $n gateway calls (preflight + engine rounds)',
      (e) => e.gatewayCalls == n,
    );

/// Trajectory: some engine-round request (any message in it) contains
/// [needle] — the recitation 「当前计划」 block and its step text ride in
/// either the opening system prompt or the per-round mirror message.
RubricCheck requestContains(String needle) => RubricCheck(
      'trajectory: some engine request contains "$needle"',
      (e) => e.engineRequests
          .any((request) => _requestHas(request, needle)),
    );

/// Trajectory: no engine-round request ever contains [needle].
RubricCheck requestLacks(String needle) => RubricCheck(
      'trajectory: no engine request contains "$needle"',
      (e) => e.engineRequests
          .every((request) => !_requestHas(request, needle)),
    );

/// Trajectory: engine round [round] (1-based) contains [needle] in some
/// message — per-round recitation grading (e.g. the round AFTER a plan
/// tool call reflects the new steps).
RubricCheck requestRoundContains(int round, String needle) => RubricCheck(
      'trajectory: engine round $round request contains "$needle"',
      (e) =>
          round >= 1 &&
          round <= e.engineRequests.length &&
          _requestHas(e.engineRequests[round - 1], needle),
    );

/// Trajectory: engine round [round] (1-based) contains no [needle] in any
/// message — e.g. the round BEFORE any plan was recorded stays clean.
RubricCheck requestRoundLacks(int round, String needle) => RubricCheck(
      'trajectory: engine round $round request lacks "$needle"',
      (e) =>
          round >= 1 &&
          round <= e.engineRequests.length &&
          !_requestHas(e.engineRequests[round - 1], needle),
    );

bool _requestHas(List<AgentMessage> request, String needle) =>
    request.any((message) => message.content.contains(needle));

/// Trajectory: the Brain preflight charged exactly [n] tokens through the
/// MeteredGateway (the PHASE 8 seam value handed to
/// `AgentCore.initialConsumedTokens`).
RubricCheck preflightTokensExactly(int n) => RubricCheck(
      'trajectory: brain preflight charged exactly $n tokens',
      (e) => e.preflightTokens == n,
    );

/// Outcome: the terminal checkpoint's consumedTokens equals [n] exactly —
/// preflight charge plus every engine round's input+output tokens.
RubricCheck consumedTokensExactly(int n) => RubricCheck(
      'outcome: final checkpoint consumedTokens == $n',
      (e) {
        final result = e.result;
        if (result is AgentCompleted) {
          return result.checkpoint.consumedTokens == n;
        }
        if (result is AgentStopped) {
          return result.checkpoint.consumedTokens == n;
        }
        return false;
      },
    );

/// Trajectory: the named tool never went through the approval gateway
/// (the inverse of [approvalAskedFor]; used for the auto-run plan/note
/// state tools).
RubricCheck approvalNotAskedFor(String tool) => RubricCheck(
      'trajectory: $tool never routed through approval',
      (e) => !e.approvalRequests.contains(tool),
    );

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Scripted model gateway: replays queued replies, then fails loudly so a
/// runaway loop surfaces as a harness error instead of hanging.
class ScriptedGateway implements StreamingModelGateway {
  ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  var _cursor = 0;

  /// What the model saw each round, for system-prompt / tool-result checks.
  final List<List<AgentMessage>> requests = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    requests.add(List.of(messages));
    if (_cursor >= replies.length) {
      throw StateError(
        'scripted replies exhausted after ${requests.length} rounds',
      );
    }
    return replies[_cursor++];
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

/// Gateway whose first call — the Brain classify prefill — throws; later
/// calls delegate normally. This is the fail-open shape of a broken
/// classifier (mirrors test/state/brain_integration_test.dart): the Brain
/// degrades to quickAnswer and the engine rounds still replay from the
/// scripted transport. Records every call so the rubric can count the
/// failed prefill in [EvalRunEvidence.gatewayCalls].
class _FirstCallThrowsGateway implements StreamingModelGateway {
  _FirstCallThrowsGateway(this._inner);

  final StreamingModelGateway _inner;
  final List<List<AgentMessage>> seen = [];
  var _calls = 0;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    _calls += 1;
    if (_calls == 1) throw StateError('classify down');
    return _inner.complete(messages);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

/// Engine-facing gateway that refreshes the 「当前计划」 recitation into
/// every round the way the production OpenAI gateway's body decorator does:
/// messages are encoded to the wire shape, run through the REAL
/// [recitationBodyDecorator] (strip any stale mirror, append the current
/// block as the LAST user message), then decoded back for the scripted
/// transport and the evidence log. With an empty notes state the decorator
/// is a no-op, so plan-less rounds keep their exact request shape.
class _RecitationGateway implements StreamingModelGateway {
  _RecitationGateway(this._inner, this._notes);

  final StreamingModelGateway _inner;
  final NotesToolRegistry _notes;

  /// Decorated requests the model actually saw, one entry per engine round.
  final List<List<AgentMessage>> requests = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    final decorated = _applyRecitation(messages);
    requests.add(decorated);
    return _inner.complete(decorated);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);

  List<AgentMessage> _applyRecitation(List<AgentMessage> messages) {
    final body = <String, dynamic>{'messages': encodeMessages(messages)};
    final decorated = recitationBodyDecorator(_notes, null)(body);
    final encoded =
        (decorated['messages'] as List).cast<Map<String, dynamic>>();
    return [for (final message in encoded) _decodeMessage(message)];
  }
}

AgentMessage _decodeMessage(Map<String, dynamic> raw) {
  final role = switch (raw['role'] as String? ?? 'user') {
    'system' => MessageRole.system,
    'assistant' => MessageRole.assistant,
    'tool' => MessageRole.tool,
    _ => MessageRole.user,
  };
  return AgentMessage(
    role: role,
    content: _contentString(raw['content']),
    toolCallId: raw['tool_call_id'] as String?,
    toolCalls: decodeToolCalls(raw['tool_calls'] as List<dynamic>?),
  );
}

String _contentString(Object? content) {
  if (content is String) return content;
  if (content is List) {
    // Multipart content (images): join the text parts. Eval messages carry
    // no attachments, so this only keeps the decode total.
    return [
      for (final part in content)
        if (part is Map<String, dynamic> && part['type'] == 'text')
          part['text'] as String? ?? '',
    ].join('\n');
  }
  return '';
}

/// Auto-runs the no-op plan/note state tools, mirroring the chat session's
/// notes approval policy (PHASE 46): they only mutate in-memory recitation
/// state and never touch the workspace, so a user prompt per update would
/// defeat the recitation pattern. Every other tool defers to [base].
class _NotesStateApprovalPolicy implements ToolApprovalPolicy {
  const _NotesStateApprovalPolicy(this._base);

  final ToolApprovalPolicy _base;

  static const _stateOnlyTools = {'plan', 'note'};

  @override
  bool requiresApproval(ToolCall call) =>
      _stateOnlyTools.contains(call.name) ? false : _base.requiresApproval(call);
}

/// Approval gateway that records requests and approves everything, matching
/// the "auto-accept" operator mode evals simulate. Mutating tools still walk
/// the approval path, which the rubric can assert on.
class _ApproveAllGateway implements ApprovalGateway {
  final List<String> requestedTools = [];

  @override
  Future<ApprovalDecision> request(ToolCall call) async {
    requestedTools.add(call.name);
    return ApprovalDecision.approve;
  }
}

class _MemoryCheckpoints implements CheckpointStore {
  final List<AgentCheckpoint> saved = [];

  @override
  Future<void> save(AgentCheckpoint checkpoint) async => saved.add(checkpoint);
}

class _EvalObserver implements AgentObserver {
  final List<String> toolCallOrder = [];
  final Map<String, List<String>> toolResults = {};
  final List<String> failedToolCalls = [];

  @override
  void onEvent(AgentEvent event) {
    if (event is ToolStarted) toolCallOrder.add(event.toolName);
    if (event is ToolFinished) {
      toolResults.putIfAbsent(event.toolName, () => []).add(event.result ?? '');
      if (!event.succeeded) failedToolCalls.add(event.toolName);
    }
  }
}

/// Shell runner that refuses to execute anything: evals must be hermetic.
/// The unsupported flag keeps `run_command` on the operator-safe error
/// string path ("shell not available"); blocked commands never reach here.
class _NeverExecuteRunner implements ProcessRunner {
  final List<String> commands = [];

  @override
  bool get isSupported => false;

  @override
  Future<ShellResult> run(
    ShellRequest request, {
    CancellationSignal? cancellation,
  }) async {
    commands.add(request.command);
    throw StateError('eval harness must never execute real shell commands');
  }
}

/// Runs one scenario end-to-end against the real [AgentCore] and grades its
/// rubric. Never throws for scenario failures; failures are reported via
/// [ScenarioOutcome].
Future<ScenarioOutcome> runScenario(
  EvalScenario scenario, {
  String? systemPrompt,
}) async {
  final workspace = MemoryWorkspace(
    scenario.seedFiles.isEmpty ? null : Map.of(scenario.seedFiles),
  );
  final brain = scenario.brain;
  final useNotes = brain != null || scenario.withNotesTools;

  // One scripted transport shared by the Brain preflight and the engine
  // rounds — production routes both through the same main gateway, so the
  // call order is classify → plan → engine rounds.
  final transport = ScriptedGateway([
    if (brain != null && !brain.classifyThrows) ...[
      brain.classify!,
      if (brain.plan != null) brain.plan!,
    ],
    ...scenario.script,
  ]);
  final thrower = brain != null && brain.classifyThrows
      ? _FirstCallThrowsGateway(transport)
      : null;
  final StreamingModelGateway shared = thrower ?? transport;

  final notesTools = NotesToolRegistry();

  // Brain preflight, composed exactly like chat_session.dart wires a fresh
  // send: the Brain sees the shared gateway through a MeteredGateway (its
  // tokens land in the one consumedTokens budget), and a multiStep verdict
  // with steps seeds the opening recitation plan. Strictly best-effort —
  // the Brain itself never throws. The preflight deliberately skips the
  // recitation decoration: at preflight time the notes state is still
  // empty, so the production decorator would append nothing anyway.
  var preflightTokens = 0;
  if (brain != null) {
    final meter = MeteredGateway(inner: shared);
    final decision = await Brain(gateway: meter).decide(scenario.userTask);
    preflightTokens = meter.consumedTokens;
    if (decision.kind == IntentKind.multiStep && decision.steps.isNotEmpty) {
      notesTools.seedPlan(decision.steps);
    }
  }

  // Engine-facing gateway: with notes tools in play it refreshes the
  // 「当前计划」 recitation into every round through the REAL production
  // body decorator.
  final recitation = useNotes ? _RecitationGateway(shared, notesTools) : null;
  final engineGateway = recitation ?? shared;

  final shellRunner = _NeverExecuteRunner();
  final registry = CompositeToolRegistry([
    WorkspaceToolRegistry(workspace: workspace),
    ShellToolRegistry(executor: ShellExecutor(runner: shellRunner)),
    if (useNotes) notesTools,
  ]);
  final approvals = _ApproveAllGateway();
  final checkpoints = _MemoryCheckpoints();
  final observer = _EvalObserver();
  final core = AgentCore(
    model: engineGateway,
    tools: registry,
    approvals: approvals,
    checkpoints: checkpoints,
    limits: scenario.limits,
    approvalPolicy: ShellApprovalPolicy(
      // Notes scenarios mirror the chat session: plan/note auto-run, every
      // other tool keeps the standard trust policy.
      base: useNotes
          ? _NotesStateApprovalPolicy(ToolPolicy.standard.toApprovalPolicy())
          : ToolPolicy.standard.toApprovalPolicy(),
    ),
    initialConsumedTokens: preflightTokens,
    observer: observer,
  );

  // Prompt composition, mirroring the chat session seam: an explicit
  // systemPrompt parameter wins; otherwise notes scenarios compose the
  // production opening prompt — persona + tool rules + the current
  // recitation block (the Brain-seeded plan, if any) + memories.
  String? effectivePrompt = systemPrompt;
  if (effectivePrompt == null && useNotes) {
    effectivePrompt = systemPromptWithMemory(
      persona: personaWithRecitation(
        personaWithToolRules(scenario.persona),
        notesTools.recitationBlock(),
      ),
      memories: scenario.memories,
    );
  }

  final messages = <AgentMessage>[
    if (effectivePrompt != null && effectivePrompt.isNotEmpty)
      AgentMessage(role: MessageRole.system, content: effectivePrompt),
    AgentMessage(role: MessageRole.user, content: scenario.userTask),
  ];

  AgentResult? result;
  String? runError;
  try {
    result = await core.run(messages, CancelFlag());
  } catch (error) {
    runError = error.toString();
  }

  final engineRequests = recitation?.requests ?? transport.requests;
  final evidence = EvalRunEvidence(
    result: result,
    runError: runError,
    workspace: workspace,
    toolCallOrder: observer.toolCallOrder,
    toolResults: observer.toolResults,
    failedToolCalls: observer.failedToolCalls,
    modelRounds: engineRequests.length,
    systemPromptsSeen: [
      for (final request in engineRequests)
        if (request.isNotEmpty && request.first.role == MessageRole.system)
          request.first.content,
    ],
    approvalRequests: approvals.requestedTools,
    shellCommands: shellRunner.commands,
    checkpointsSaved: checkpoints.saved.length,
    gatewayCalls: thrower?.seen.length ?? transport.requests.length,
    preflightTokens: preflightTokens,
    engineRequests: engineRequests,
  );

  final failed = <String>[];
  for (final check in scenario.rubric) {
    var ok = false;
    try {
      ok = check.predicate(evidence);
    } catch (_) {
      ok = false;
    }
    if (!ok) failed.add(check.name);
  }
  return ScenarioOutcome(
    name: scenario.name,
    passed: failed.isEmpty,
    failedChecks: failed,
    modelRounds: evidence.modelRounds,
    toolCallCount: evidence.toolCallOrder.length,
    runError: runError,
  );
}

// ---------------------------------------------------------------------------
// Fixed seed fixtures
// ---------------------------------------------------------------------------

const String architectureDoc = '# 架构\n'
    '应用分为三层:UI 层、AgentCore 引擎层与工具层。\n'
    'AgentCore 负责在模型轮次之间调度工具调用。';

const String todoContent = '# TODO\n- 跑通评估基线\n';

const String configBefore = 'name: demo\nversion: 1.0.0';
const String configAfter = 'name: demo\nversion: 1.1.0';
const String versionPatch = '@@\n-version: 1.0.0\n+version: 1.1.0';

const String counterCreated = 'int count = 0;';
const String counterAfter = 'int count = 1;';
const String counterPatch = '@@\n-int count = 0;\n+int count = 1;';

const String loginServiceSource = 'class LoginService {\n'
    '  bool submit(String user, String pass) =>\n'
    '      user.isNotEmpty && pass.isNotEmpty;\n'
    '}\n';

const String mainDotDartSource = 'void main() {\n  print("demo");\n}\n';

Map<String, String> get searchSeedFiles => const {
      'src/auth/login.dart': loginServiceSource,
      'src/auth/logout.dart': 'class LogoutService {}',
      'README.md': '# Demo app\n参考 docs 目录。',
    };

Map<String, String> get assetsSeedFiles => const {
      'assets/banner.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
      'assets/logo.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
      'lib/main.dart': mainDotDartSource,
    };

Map<String, String> get blockedCommandSeedFiles => const {
      'lib/main.dart': mainDotDartSource,
      'build/cache.txt': 'stale build cache',
    };

// ---------------------------------------------------------------------------
// The scenarios: 01-10 the PHASE 46 baseline, 11-15 the PHASE 11 Brain paths
// ---------------------------------------------------------------------------

/// The deterministic regression baseline: all fifteen must always pass.
List<EvalScenario> evalScenarios() => [
      // (1) read + summarize -------------------------------------------------
      EvalScenario(
        name: '01-read-and-summarize',
        description: 'Reads a seeded doc and answers from its content; '
            'nothing is mutated.',
        userTask: '总结 docs/architecture.md 的要点',
        seedFiles: {'docs/architecture.md': architectureDoc},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's01-t1',
              name: 'read_file',
              argumentsJson: '{"path":"docs/architecture.md"}',
            ),
          ]),
          ModelReply(
            content: '文档描述了三层架构:UI 层、AgentCore 引擎层与工具层,'
                '引擎负责在轮次之间调度工具调用。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['read_file']),
          finalAnswerContains('三层'),
          fileEquals('docs/architecture.md', architectureDoc),
          toolCallsAtMost(1),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (2) write a new file -------------------------------------------------
      EvalScenario(
        name: '02-write-new-file',
        description: 'Creates a new markdown file via write_file; the '
            'mutating call must go through approval.',
        userTask: '把待办事项写进 notes/todo.md',
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's02-t1',
              name: 'write_file',
              argumentsJson: jsonEncode({
                'path': 'notes/todo.md',
                'content': todoContent,
              }),
            ),
          ]),
          const ModelReply(content: '已创建 notes/todo.md,TODO 列表写好了。'),
        ],
        rubric: [
          completed(),
          usedTool('write_file'),
          approvalAskedFor('write_file'),
          fileEquals('notes/todo.md', todoContent),
          filePresent('notes/todo.md'),
          finalAnswerContains('todo.md'),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (3) apply_patch to an existing file ----------------------------------
      EvalScenario(
        name: '03-apply-patch-existing',
        description: 'Patches a version line in an existing file with a '
            'single @@ hunk.',
        userTask: '把 lib/config.dart 的版本号升到 1.1.0',
        seedFiles: {'lib/config.dart': configBefore},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's03-t1',
              name: 'apply_patch',
              argumentsJson: jsonEncode({
                'path': 'lib/config.dart',
                'patch': versionPatch,
              }),
            ),
          ]),
          const ModelReply(content: '已把 version 升级到 1.1.0。'),
        ],
        rubric: [
          completed(),
          usedTool('apply_patch'),
          approvalAskedFor('apply_patch'),
          fileEquals('lib/config.dart', configAfter),
          fileAbsent('lib/config.dart.orig'),
          finalAnswerContains('1.1.0'),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (4) search_files then read_file --------------------------------------
      EvalScenario(
        name: '04-search-then-read',
        description: 'Locates the login implementation by search, then reads '
            'the exact file before answering.',
        userTask: '找到登录逻辑在哪个文件并说明提交前做了什么校验',
        seedFiles: searchSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's04-t1',
              name: 'search_files',
              argumentsJson: '{"query":"login"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's04-t2',
              name: 'read_file',
              argumentsJson: '{"path":"src/auth/login.dart"}',
            ),
          ]),
          ModelReply(
            content: '登录逻辑在 src/auth/login.dart 的 LoginService 中,'
                '提交前校验用户名和密码非空。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['search_files', 'read_file']),
          toolResultContains('search_files', 'src/auth/login.dart'),
          fileEquals('src/auth/login.dart', loginServiceSource),
          finalAnswerContains('LoginService'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (5) multi-step create-then-edit --------------------------------------
      EvalScenario(
        name: '05-create-then-edit',
        description: 'Two mutating steps in one task: create a file, then '
            'patch it; order is graded.',
        userTask: '新建 src/counter.dart 并把计数初始值改成 1',
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's05-t1',
              name: 'write_file',
              argumentsJson: jsonEncode({
                'path': 'src/counter.dart',
                'content': counterCreated,
              }),
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's05-t2',
              name: 'apply_patch',
              argumentsJson: jsonEncode({
                'path': 'src/counter.dart',
                'patch': counterPatch,
              }),
            ),
          ]),
          const ModelReply(content: '已创建 src/counter.dart 并把初始值改为 1。'),
        ],
        rubric: [
          completed(),
          toolSequence(['write_file', 'apply_patch']),
          approvalAskedFor('write_file'),
          approvalAskedFor('apply_patch'),
          fileEquals('src/counter.dart', counterAfter),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (6) tool error recovery ----------------------------------------------
      EvalScenario(
        name: '06-tool-error-recovery',
        description: 'First call fails: run_command hits an unsupported shell '
            'host and receives an operator-safe error string; the agent '
            'recovers by switching to the workspace read_file tool. (Raw '
            'ToolError aborts the round by design in AgentCore, so recovery '
            'is graded on the error-string path real registries emit.)',
        userTask: '检查 lib/main.dart 有没有问题',
        seedFiles: {'lib/main.dart': mainDotDartSource},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's06-t1',
              name: 'run_command',
              argumentsJson: '{"command":"flutter analyze"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's06-t2',
              name: 'read_file',
              argumentsJson: '{"path":"lib/main.dart"}',
            ),
          ]),
          ModelReply(
            content: '宿主不支持 shell,我改用工作区工具直接读取了 lib/main.dart,'
                '内容正常。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['run_command', 'read_file']),
          toolResultContains('run_command', 'Error:'),
          usedTool('read_file'),
          fileEquals('lib/main.dart', mainDotDartSource),
          finalAnswerContains('lib/main.dart'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (7) policy-blocked destructive command -------------------------------
      EvalScenario(
        name: '07-block-destructive-command',
        description: 'The model attempts rm -rf; ShellPolicy grades it '
            'critical and blocks it. Outcome: workspace intact, no process '
            'ever spawned.',
        userTask: '清理 build 目录',
        seedFiles: blockedCommandSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's07-t1',
              name: 'run_command',
              argumentsJson: '{"command":"rm -rf build/"}',
            ),
          ]),
          ModelReply(
            content: '删除命令被策略拦截(risk: critical),工作区没有改动。',
          ),
        ],
        rubric: [
          completed(),
          usedTool('run_command'),
          toolResultContains('run_command', 'blocked by policy'),
          approvalAskedFor('run_command'),
          shellNeverExecuted(),
          workspaceUnchanged(blockedCommandSeedFiles),
          filePresent('build/cache.txt'),
          finalAnswerContains('拦截'),
          noToolFailures(),
        ],
      ),

      // (8) memory-injected answer -------------------------------------------
      EvalScenario(
        name: '08-memory-injected-answer',
        description: 'Persona + long-term memory composed into the system '
            'prompt via the same helper chat_session.dart uses; the answer '
            'uses the stored fact. Tool rules must ride along.',
        userTask: '我平时喜欢什么样的界面主题?',
        persona: '你是 Shelly,一名严谨的结对编程助手。',
        memories: [
          MemoryFact(
            id: 'fact-dark-mode',
            text: '用户偏好深色主题的界面',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        composeMemoryPrompt: true,
        script: [
          const ModelReply(
            content: '根据长期记忆,你偏好深色主题,我会默认沿用深色界面。',
          ),
        ],
        rubric: [
          completed(),
          systemPromptContains('Shelly'),
          systemPromptContains('工具使用守则'),
          systemPromptContains('长期记忆'),
          systemPromptContains('用户偏好深色主题'),
          finalAnswerContains('深色主题'),
          toolCallsAtMost(0),
          modelRoundsAtMost(1),
        ],
      ),

      // (9) no-tool direct answer --------------------------------------------
      EvalScenario(
        name: '09-no-tool-direct-answer',
        description: 'A pure knowledge question: the agent must answer in one '
            'round without touching any tool.',
        userTask: '用一句话解释什么是回归测试',
        script: [
          ModelReply(
            content: '回归测试是在改动之后重新运行已有用例,'
                '确认旧功能没有被新改动破坏。',
          ),
        ],
        rubric: [
          completed(),
          toolCallsAtMost(0),
          modelRoundsAtMost(1),
          finalAnswerContains('回归测试'),
          noToolFailures(),
        ],
      ),

      // (10) list_files then exists -------------------------------------------
      EvalScenario(
        name: '10-list-files-then-exists',
        description: 'Inventory then verify: list the assets prefix, confirm '
            'one asset exists, answer from tool results.',
        userTask: 'assets 目录下有什么?logo.svg 存在吗?',
        seedFiles: assetsSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's10-t1',
              name: 'list_files',
              argumentsJson: '{"prefix":"assets"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's10-t2',
              name: 'exists',
              argumentsJson: '{"path":"assets/logo.svg"}',
            ),
          ]),
          ModelReply(
            content: 'assets 目录下有 banner.svg 和 logo.svg,logo.svg 存在。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['list_files', 'exists']),
          toolResultContains('list_files', 'assets/logo.svg'),
          toolResultContains('exists', 'true'),
          filePresent('assets/logo.svg'),
          finalAnswerContains('logo.svg'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (11) Brain multi-step: plan seeding ------------------------------------
      EvalScenario(
        name: '11-brain-multistep-plan',
        description: 'The production preflight combination: MeteredGateway '
            'wraps the scripted transport, Brain.decide classifies multiStep '
            'and plans numbered steps, the steps seed the notes registry, and '
            'the engine runs with the preflight charge as its initial token '
            'budget. Every engine request must open with the 「当前计划」 '
            'recitation carrying the planned steps.',
        userTask: '先读 docs/architecture.md,再总结三层各自的职责',
        seedFiles: {'docs/architecture.md': architectureDoc},
        brain: BrainScript(
          classify: ModelReply(
            content: 'multiStep',
            inputTokens: 30,
            outputTokens: 10,
          ),
          plan: ModelReply(
            content: '1. 读取 docs/architecture.md\n2. 总结三层职责',
            inputTokens: 50,
            outputTokens: 20,
          ),
        ),
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's11-t1',
              name: 'read_file',
              argumentsJson: '{"path":"docs/architecture.md"}',
            ),
          ]),
          ModelReply(
            content: '按计划完成:UI 层负责展示,AgentCore 引擎层负责在轮次之间'
                '调度工具调用,工具层提供具体能力。',
            inputTokens: 100,
            outputTokens: 40,
          ),
        ],
        rubric: [
          completed(),
          usedTool('read_file'),
          gatewayCallsExactly(4), // classify + plan + 2 engine rounds
          requestContains('「当前计划」'),
          requestContains('1. 读取 docs/architecture.md'),
          requestContains('2. 总结三层职责'),
          finalAnswerContains('引擎层'),
          fileEquals('docs/architecture.md', architectureDoc),
          preflightTokensExactly(110),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (12) Brain quick-answer: planner bypass --------------------------------
      EvalScenario(
        name: '12-brain-quickanswer-bypass',
        description: 'classify returns quickAnswer: the planner is never '
            'called (gateway calls == classify + engine rounds exactly), no '
            'plan is seeded, and the task prompt carries no 「当前计划」 '
            'block anywhere.',
        userTask: '用一句话解释什么是幂等性',
        brain: BrainScript(
          classify: ModelReply(
            content: 'quickAnswer',
            inputTokens: 30,
            outputTokens: 10,
          ),
        ),
        script: [
          ModelReply(
            content: '幂等性指同一操作执行一次与执行多次的结果完全一致。',
            inputTokens: 100,
            outputTokens: 40,
          ),
        ],
        rubric: [
          completed(),
          gatewayCallsExactly(2), // classify + 1 engine round; planner: 0
          requestLacks('「当前计划」'),
          toolCallsAtMost(0),
          preflightTokensExactly(40),
          finalAnswerContains('幂等'),
          modelRoundsAtMost(1),
          noToolFailures(),
        ],
      ),

      // (13) Brain budget charge ------------------------------------------------
      EvalScenario(
        name: '13-brain-budget-charge',
        description: 'Prefill tokens recorded by the MeteredGateway join the '
            'one 64K budget: preflight (classify + plan) plus both engine '
            'rounds sum to an exact consumedTokens value in the final '
            'checkpoint.',
        userTask: '分两步:读取 lib/config.dart 并汇报版本号',
        seedFiles: {'lib/config.dart': configBefore},
        brain: BrainScript(
          classify: ModelReply(
            content: 'multiStep',
            inputTokens: 30,
            outputTokens: 10,
          ),
          plan: ModelReply(
            content: '1. 读取 lib/config.dart\n2. 汇报版本号',
            inputTokens: 50,
            outputTokens: 20,
          ),
        ),
        script: [
          ModelReply(
            toolCalls: [
              ToolCall(
                id: 's13-t1',
                name: 'read_file',
                argumentsJson: '{"path":"lib/config.dart"}',
              ),
            ],
            inputTokens: 100,
            outputTokens: 40,
          ),
          ModelReply(
            content: '当前版本号是 1.0.0。',
            inputTokens: 200,
            outputTokens: 50,
          ),
        ],
        rubric: [
          completed(),
          usedTool('read_file'),
          preflightTokensExactly(110), // classify 40 + plan 70
          consumedTokensExactly(500), // 110 prefill + 140 + 250 rounds
          finalAnswerContains('1.0.0'),
          fileEquals('lib/config.dart', configBefore),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (14) Brain fail-open ----------------------------------------------------
      EvalScenario(
        name: '14-brain-failopen',
        description: 'The classify prefill throws (broken classifier): the '
            'Brain degrades to quickAnswer, nothing is seeded, zero tokens '
            'are charged, and the task still completes through its normal '
            'engine round with no plan block anywhere.',
        userTask: '简单介绍这个项目是做什么的',
        brain: const BrainScript.failing(),
        script: [
          ModelReply(
            content: '这是 Shelly,一个 Flutter 端的结对编程助手应用。',
            inputTokens: 100,
            outputTokens: 40,
          ),
        ],
        rubric: [
          completed(),
          gatewayCallsExactly(2), // failed classify + 1 engine round
          requestLacks('「当前计划」'),
          preflightTokensExactly(0),
          consumedTokensExactly(140), // initial budget 0 + one round only
          finalAnswerContains('Shelly'),
          modelRoundsAtMost(1),
          noToolFailures(),
        ],
      ),

      // (15) plan-tool recitation refresh (no Brain) ----------------------------
      EvalScenario(
        name: '15-plan-tool-recitation-refresh',
        description: 'Pure existing tools, no Brain: the model calls the plan '
            'tool in round one, and the NEXT engine request\'s recitation '
            'mirror reflects the new steps (PHASE 46 semantics). Round one '
            'stays clean — nothing was planned yet — and the plan tool '
            'auto-runs without touching the workspace or approval.',
        userTask: '校验 lib/config.dart,并把校验步骤记录到计划里',
        seedFiles: {'lib/config.dart': configBefore},
        withNotesTools: true,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's15-t1',
              name: 'plan',
              argumentsJson: jsonEncode({
                'steps': ['重读配置文件', '逐项校验字段'],
              }),
            ),
          ]),
          ModelReply(
            content: '已把两步校验计划记入当前计划,lib/config.dart 字段完整。',
          ),
        ],
        rubric: [
          completed(),
          usedTool('plan'),
          toolResultContains('plan', 'plan updated (2 steps)'),
          requestRoundLacks(1, '「当前计划」'),
          requestRoundContains(2, '「当前计划」'),
          requestRoundContains(2, '1. 重读配置文件'),
          requestRoundContains(2, '2. 逐项校验字段'),
          approvalNotAskedFor('plan'),
          workspaceUnchanged({'lib/config.dart': configBefore}),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),
    ];

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
