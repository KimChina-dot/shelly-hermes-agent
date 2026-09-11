// V3.1 搬迁锚点(PHASE 19 冻结,V3 计划 P14):move → lib/agent/runtime/agent_runtime.dart。
// 引擎组装职责归 agent 层(与 brain/ 同层);agent_context.dart 原地不动。
// 命令与风险见 docs/audit/V31_MIGRATION_CHECKLIST.md M5;本模块不经 facade,
// 替换面 = chat_session 直连 + 2 个测试文件。
// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../agent_core.dart';
import '../approval_broker.dart';
import '../models.dart';
import '../tools/registry.dart';
import 'agent_context.dart';

/// Owns engine assembly and the task lifecycle around [AgentCore]:
///
/// - Hermes recall before the first round (context injection)
/// - Hermes remember after completion (experience bookkeeping)
/// - Policy resolution and limit wiring
///
/// The UI layer no longer touches engine internals: it hands over an
/// [AgentContext] plus the approval gateway and observer, and receives a
/// plain [AgentResult].
class AgentRuntime {
  AgentRuntime({
    required this.context,
    required ApprovalGateway approvals,
    AgentObserver? observer,
  })  : _approvals = approvals,
        _observer = observer;

  final AgentContext context;
  final ApprovalGateway _approvals;
  final AgentObserver? _observer;

  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    final effective = await _injectMemory(messages, resumeFrom);
    final core = AgentCore(
      model: context.model,
      tools: context.tools,
      approvals: _approvals,
      checkpoints: context.checkpoints,
      limits: context.limits,
      approvalPolicy:
          context.approvalPolicy ?? ToolPolicy.standard.toApprovalPolicy(),
      contextCompactor: context.contextCompactor,
      initialConsumedTokens: context.initialConsumedTokens,
      observer: _observer,
    );
    final result = await core.run(effective, cancellation, resumeFrom: resumeFrom);
    await _offerMemory(result);
    return result;
  }

  /// Prepends recalled knowledge as a system message so the model starts
  /// from prior experience instead of exploring from scratch. A resume must
  /// not re-inject: the checkpoint already contains the earlier context.
  Future<List<AgentMessage>> _injectMemory(
    List<AgentMessage> messages,
    AgentCheckpoint? resumeFrom,
  ) async {
    final hermes = context.hermes;
    if (hermes == null || resumeFrom != null || messages.isEmpty) {
      return messages;
    }
    final task = messages.last.content;
    if (task.trim().isEmpty) return messages;
    try {
      final knowledge = await hermes.recall(task);
      if (knowledge.isEmpty) return messages;
      return [
        AgentMessage(
          role: MessageRole.system,
          content: '以下是 Hermes 记忆库中与该任务相关的历史经验,优先参考:\n'
              '- ${knowledge.join('\n- ')}',
        ),
        ...messages,
      ];
    } catch (_) {
      return messages;
    }
  }

  Future<void> _offerMemory(AgentResult result) async {
    final hermes = context.hermes;
    if (hermes == null || result is! AgentCompleted) return;
    if (result.message.trim().isEmpty) return;
    try {
      await hermes.maybeRemember(result.message, result.checkpoint);
    } catch (_) {
      // Experience bookkeeping is best-effort by design.
    }
  }
}
