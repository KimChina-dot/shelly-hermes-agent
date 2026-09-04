import '../agent_core.dart';
import '../context/context_compactor.dart';
import '../models.dart';
import '../tools/workspace.dart';
import '../workspace/project.dart';
import 'tool_registry.dart';

/// Seam for the Hermes memory system (PHASE 06+). The runtime consults it
/// before a task starts and offers it the finished transcript afterwards;
/// failures are always swallowed — memory must never break execution.
abstract interface class AgentMemoryAccess {
  /// Knowledge snippets relevant to [task], injected as a system message.
  Future<List<String>> recall(String task);

  /// Called on task completion; the implementation decides whether the
  /// transcript contains a lesson worth keeping.
  Future<void> maybeRemember(String finalReply, AgentCheckpoint checkpoint);
}

/// Everything one agent task needs, resolved up front. The UI layer builds
/// this once; the runtime turns it into an executable [AgentCore].
class AgentContext {
  const AgentContext({
    required this.sessionId,
    required this.workspace,
    required this.model,
    required this.tools,
    required this.checkpoints,
    this.hermes,
    this.taskId,
    this.project,
    this.contextCompactor,
    this.limits = const AgentLimits(maxRounds: 16, maxToolCalls: 32),
    this.approvalPolicy,
  });

  /// Conversation/task identifier used for checkpoint scoping.
  final String sessionId;
  final String? taskId;

  /// Shelly execution environment (file access root).
  final Workspace workspace;

  /// Model gateway, already configured (endpoint, key, model name).
  final ModelGateway model;

  /// Unified tool surface: core workspace tools plus any DSH plugin tools.
  final AgentToolRegistry tools;

  final CheckpointStore checkpoints;
  final AgentMemoryAccess? hermes;

  /// Workspace project detection (PHASE 03): kind/name/git, consumed by
  /// Hermes (per-project knowledge) and DSH (permission scoping).
  final ProjectInfo? project;

  /// Null resolves to the standard policy (read-only allow, writes confirm).
  final ToolApprovalPolicy? approvalPolicy;
  final AgentLimits limits;

  /// Null disables context compaction (small demos, tests). When set, the
  /// core folds older exchanges into a summary before each model round.
  final ContextCompactor? contextCompactor;
}
