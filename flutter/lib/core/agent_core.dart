// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import 'approval_broker.dart';
import 'gateway/openai_gateway.dart' show CachedTokensReply;
import 'context/context_compactor.dart';
import 'diff_hunk_approval.dart';
import 'models.dart';

/// Cooperative cancellation checked between model rounds, tool calls and
/// pending-queue drain steps.
abstract interface class CancellationSignal {
  bool get isCancelled;
}

/// Mutable flag implementation handed to task runners.
class CancelFlag implements CancellationSignal {
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  @override
  bool get isCancelled => _cancelled;
}

abstract interface class ModelGateway {
  Future<ModelReply> complete(List<AgentMessage> messages);
}

/// Optional capability implemented by gateways that can deliver model output
/// while it arrives. The engine prefers this when the gateway implements it.
abstract interface class StreamingModelGateway implements ModelGateway {
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  );
}

abstract interface class ToolExecutor {
  Future<String> execute(ToolCall call);
}

abstract interface class CheckpointStore {
  Future<void> save(AgentCheckpoint checkpoint);
}

abstract interface class AgentObserver {
  void onEvent(AgentEvent event);
}

abstract interface class ToolApprovalPolicy {
  bool requiresApproval(ToolCall call);
}

/// Preserves the original behavior: every tool call requires user approval.
const toolApprovalRequireAll = _RequireAllPolicy();

class _RequireAllPolicy implements ToolApprovalPolicy {
  const _RequireAllPolicy();

  @override
  bool requiresApproval(ToolCall call) => true;
}

/// Skips the approval round-trip for explicitly trusted read-only tools.
/// Callers should only add tools that cannot mutate state or leak data.
class AutoApproveReadOnlyPolicy implements ToolApprovalPolicy {
  AutoApproveReadOnlyPolicy({
    Set<String> toolNames = const {
      'read_file',
      'exists',
      'list_files',
      'search_files',
      'repo_map',
      'batch_read',
    },
  }) : _toolNames = toolNames;

  final Set<String> _toolNames;

  @override
  bool requiresApproval(ToolCall call) => !_toolNames.contains(call.name);
}

sealed class AgentResult {
  const AgentResult();
}

class AgentCompleted extends AgentResult {
  const AgentCompleted(this.message, this.checkpoint);
  final String message;
  final AgentCheckpoint checkpoint;
}

class AgentStopped extends AgentResult {
  const AgentStopped(this.reason, this.checkpoint);
  final String reason;
  final AgentCheckpoint checkpoint;
}

class AgentCore {
  AgentCore({
    required ModelGateway model,
    required ToolExecutor tools,
    required ApprovalGateway approvals,
    required CheckpointStore checkpoints,
    this.limits = const AgentLimits(),
    this.approvalPolicy = toolApprovalRequireAll,
    this.contextCompactor,
    this.initialConsumedTokens = 0,
    AgentObserver? observer,
  })  : _model = model,
        _streamingModel = model is StreamingModelGateway ? model : null,
        _tools = tools,
        _approvals = approvals,
        _checkpoints = checkpoints,
        _observer = observer;

  final ModelGateway _model;
  final StreamingModelGateway? _streamingModel;
  final ToolExecutor _tools;
  final ApprovalGateway _approvals;
  final CheckpointStore _checkpoints;
  final AgentLimits limits;
  final ToolApprovalPolicy approvalPolicy;
  final ContextCompactor? contextCompactor;
  final AgentObserver? _observer;

  /// Tokens charged before the first round (PHASE 8 Brain preflight); they
  /// share the one maxTokens budget with the agent rounds. A resume's
  /// checkpoint value always wins over this seed.
  final int initialConsumedTokens;

  Future<AgentResult> run(
    List<AgentMessage> initialMessages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    final messages = List<AgentMessage>.from(resumeFrom?.messages ?? initialMessages);
    var round = resumeFrom?.round ?? 0;
    var consumedTokens =
        resumeFrom?.consumedTokens ?? initialConsumedTokens;
    var toolCallCount = resumeFrom?.toolCalls ?? 0;
    final pendingToolCalls = List<PendingToolCall>.from(
      resumeFrom?.pendingToolCalls ?? const <PendingToolCall>[],
    );

    AgentCheckpoint snapshot() => AgentCheckpoint(
          messages: List.of(messages),
          round: round,
          consumedTokens: consumedTokens,
          toolCalls: toolCallCount,
          pendingToolCalls: List.of(pendingToolCalls),
        );

    // Telemetry must never be able to stop the agent loop.
    void emit(AgentEvent event) {
      try {
        _observer?.onEvent(event);
      } catch (_) {}
    }

    int elapsedMillis(Stopwatch started) => started.elapsedMilliseconds;

    Future<void> executePending(ToolCall call,
        {required bool approvedByResume}) async {
      var executionCall = call;
      if (!approvedByResume) {
        final approvalCalls = DiffHunkApproval.expand(call);
        var requiresApproval = true;
        try {
          requiresApproval = approvalPolicy.requiresApproval(call);
        } catch (_) {
          // Fail closed: a broken policy must never bypass user approval.
          requiresApproval = true;
        }
        var approved = true;
        var rejectedAll = false;
        if (requiresApproval) {
          final approvedHunks = <ToolCall>[];
          for (final approvalCall in approvalCalls) {
            emit(ApprovalWaiting(approvalCall));
            final approvalStarted = Stopwatch()..start();
            ApprovalDecision hunkDecision;
            try {
              hunkDecision = await _approvals.request(approvalCall);
              emit(ApprovalFinished(
                call: approvalCall,
                durationMillis: elapsedMillis(approvalStarted),
                decision: hunkDecision,
              ));
            } catch (error) {
              emit(ApprovalFinished(
                call: approvalCall,
                durationMillis: elapsedMillis(approvalStarted),
                decision: null,
              ));
              rethrow;
            }
            if (hunkDecision == ApprovalDecision.approve) {
              approvedHunks.add(approvalCall);
            } else {
              approved = false;
              break;
            }
          }
          if (!approved) {
            if (approvedHunks.isNotEmpty) {
              executionCall = DiffHunkApproval.collapse(approvedHunks);
            } else {
              rejectedAll = true;
            }
          }
        }
        if (rejectedAll) {
          pendingToolCalls.clear();
          await _checkpoints.save(snapshot());
          messages.add(const AgentMessage(
            role: MessageRole.tool,
            content: 'Tool call rejected by user',
          ));
          await _checkpoints.save(snapshot());
          return;
        }
      }

      pendingToolCalls
        ..clear()
        ..add(PendingToolCall(call: executionCall, stage: ToolExecutionStage.awaitingExecution));
      await _checkpoints.save(snapshot());
      pendingToolCalls
        ..clear()
        ..add(PendingToolCall(call: executionCall, stage: ToolExecutionStage.running));
      await _checkpoints.save(snapshot());
      emit(ToolStarted(executionCall.id, executionCall.name, executionCall.argumentsJson));
      final toolStarted = Stopwatch()..start();
      String result;
      try {
        result = await _tools.execute(executionCall);
        emit(ToolFinished(
          toolCallId: executionCall.id,
          toolName: executionCall.name,
          durationMillis: elapsedMillis(toolStarted),
          succeeded: true,
          result: result,
        ));
      } catch (error) {
        emit(ToolFinished(
          toolCallId: executionCall.id,
          toolName: executionCall.name,
          durationMillis: elapsedMillis(toolStarted),
          succeeded: false,
          result: error.toString(),
        ));
        rethrow;
      }
      pendingToolCalls.clear();
      await _checkpoints.save(snapshot());
      messages.add(AgentMessage(
        role: MessageRole.tool,
        content: result,
        toolCallId: executionCall.id,
      ));
      await _checkpoints.save(snapshot());
    }

    // Drain an interrupted pending queue first. A RUNNING stage means the
    // process died while execution may already have mutated the workspace;
    // do not silently rerun it — return to the user for an explicit decision.
    while (pendingToolCalls.isNotEmpty) {
      if (cancellation.isCancelled) {
        return AgentStopped('cancelled', snapshot());
      }
      final pending = pendingToolCalls.removeAt(0);
      if (pending.stage == ToolExecutionStage.running) {
        pendingToolCalls.insert(
          0,
          PendingToolCall(call: pending.call, stage: ToolExecutionStage.awaitingApproval),
        );
        await _checkpoints.save(snapshot());
      }
      await executePending(
        pending.call,
        approvedByResume: pending.stage == ToolExecutionStage.awaitingExecution,
      );
    }

    while (round < limits.maxRounds) {
      if (cancellation.isCancelled) {
        return AgentStopped('cancelled', snapshot());
      }
      // Fold older exchanges into a summary before the model call when the
      // transcript has grown past the model's usable context window.
      final compactor = contextCompactor;
      if (compactor != null && compactor.needsCompaction(messages)) {
        try {
          final result = await compactor.compact(messages);
          if (result.droppedMessages > 0) {
            messages
              ..clear()
              ..addAll(result.messages);
            await _checkpoints.save(snapshot());
            emit(ContextCompacted(
              droppedMessages: result.droppedMessages,
              tokensBefore: result.tokensBefore,
              tokensAfter: result.tokensAfter,
              usedModelSummary: result.usedModelSummary,
            ));
          }
        } catch (_) {
          // Compaction is best-effort; an overflowing request is preferable
          // to a compactor failure killing the task.
        }
      }
      final modelRound = round + 1;
      emit(ModelStarted(modelRound));
      final modelStarted = Stopwatch()..start();
      ModelReply reply;
      try {
        final streaming = _streamingModel;
        if (streaming == null) {
          reply = await _model.complete(messages);
        } else {
          reply = await streaming.completeStreaming(messages, (text) {
            if (text.isNotEmpty) emit(ModelDelta(text));
          });
        }
      } catch (error) {
        emit(ModelFinished(
          round: modelRound,
          durationMillis: elapsedMillis(modelStarted),
          succeeded: false,
        ));
        rethrow;
      }
      emit(ModelFinished(
        round: modelRound,
        durationMillis: elapsedMillis(modelStarted),
        succeeded: true,
        inputTokens: reply.inputTokens,
        outputTokens: reply.outputTokens,
        cachedTokens: switch (reply) {
          final CachedTokensReply cached => cached.promptCachedTokens,
          _ => 0,
        },
      ));
      round += 1;
      consumedTokens += reply.inputTokens + reply.outputTokens;
      if (consumedTokens > limits.maxTokens) {
        return AgentStopped('token_budget_exceeded', snapshot());
      }

      if (reply.content.trim().isNotEmpty || reply.toolCalls.isNotEmpty) {
        messages.add(AgentMessage(
          role: MessageRole.assistant,
          content: reply.content,
          toolCalls: reply.toolCalls,
        ));
      }
      if (reply.toolCalls.isEmpty) {
        final checkpoint = snapshot();
        await _checkpoints.save(checkpoint);
        return AgentCompleted(reply.content, checkpoint);
      }

      for (final call in reply.toolCalls) {
        if (cancellation.isCancelled) {
          return AgentStopped('cancelled', snapshot());
        }
        toolCallCount += 1;
        if (toolCallCount > limits.maxToolCalls) {
          return AgentStopped('tool_budget_exceeded', snapshot());
        }
        pendingToolCalls
          ..clear()
          ..add(PendingToolCall(call: call, stage: ToolExecutionStage.awaitingApproval));
        await _checkpoints.save(snapshot());
        await executePending(call, approvedByResume: false);
      }
    }
    return AgentStopped('round_limit_exceeded', snapshot());
  }
}
