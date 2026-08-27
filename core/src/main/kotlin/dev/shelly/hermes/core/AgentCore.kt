package dev.shelly.hermes.core

interface CancellationSignal {
    val isCancelled: Boolean
}

fun interface ModelGateway {
    suspend fun complete(messages: List<AgentMessage>): ModelReply
}

/** Optional capability implemented by gateways that can deliver model output while it arrives. */
fun interface StreamingModelGateway {
    suspend fun completeStreaming(
        messages: List<AgentMessage>,
        onDelta: (String) -> Unit,
    ): ModelReply
}

fun interface ToolExecutor {
    suspend fun execute(call: ToolCall): String
}

enum class ApprovalDecision { APPROVE, REJECT }

fun interface ApprovalGateway {
    suspend fun request(call: ToolCall): ApprovalDecision
}

fun interface CheckpointStore {
    suspend fun save(checkpoint: AgentCheckpoint)
}

fun interface AgentObserver {
    fun onEvent(event: AgentEvent)

    companion object {
        val NONE = AgentObserver { }
    }
}

fun interface ToolApprovalPolicy {
    fun requiresApproval(call: ToolCall): Boolean

    companion object {
        /** Preserves the original behavior: every tool call requires user approval. */
        val REQUIRE_ALL = ToolApprovalPolicy { true }

        /**
         * Skips the approval round-trip for explicitly trusted read-only tools.
         * Callers should only add tools that cannot mutate state or leak data.
         */
        fun autoApproveReadOnly(
            toolNames: Set<String> = setOf("read_file", "exists", "list_files", "search_files")
        ) = ToolApprovalPolicy { call -> call.name !in toolNames }
    }
}

sealed interface AgentResult {
    data class Completed(val message: String, val checkpoint: AgentCheckpoint) : AgentResult
    data class Stopped(val reason: String, val checkpoint: AgentCheckpoint) : AgentResult
}

class AgentCore(
    private val model: ModelGateway,
    private val tools: ToolExecutor,
    private val approvals: ApprovalGateway,
    private val checkpoints: CheckpointStore,
    private val limits: AgentLimits = AgentLimits(),
    private val approvalPolicy: ToolApprovalPolicy = ToolApprovalPolicy.REQUIRE_ALL,
    private val observer: AgentObserver = AgentObserver.NONE,
    private val nanoTime: () -> Long = System::nanoTime
) {
    private val streamingModel = model as? StreamingModelGateway

    suspend fun run(
        initialMessages: List<AgentMessage>,
        cancellation: CancellationSignal,
        resumeFrom: AgentCheckpoint? = null,
    ): AgentResult {
        val messages = (resumeFrom?.messages ?: initialMessages).toMutableList()
        var round = resumeFrom?.round ?: 0
        var consumedTokens = resumeFrom?.consumedTokens ?: 0
        var toolCallCount = resumeFrom?.toolCalls ?: 0

        var pendingToolCalls = resumeFrom?.pendingToolCalls.orEmpty().toMutableList()

        fun snapshot() = AgentCheckpoint(
            messages.toList(),
            round,
            consumedTokens,
            toolCallCount,
            pendingToolCalls.toList(),
        )
        fun emit(event: AgentEvent) {
            // Telemetry must never be able to stop the agent loop.
            runCatching { observer.onEvent(event) }
        }
        fun elapsedMillis(startNanos: Long): Long =
            ((nanoTime() - startNanos) / 1_000_000L).coerceAtLeast(0L)

        suspend fun executePending(call: ToolCall, approvedByResume: Boolean) {
            var executionCall = call
            if (!approvedByResume) {
                val approvalCalls = DiffHunkApproval.expand(call)
                val requiresApproval = try {
                    approvalPolicy.requiresApproval(call)
                } catch (_: Throwable) {
                    // Fail closed: a broken policy must never bypass user approval.
                    true
                }
                var approved = true
                var rejectedAll = false
                if (requiresApproval) {
                    val approvedHunks = mutableListOf<ToolCall>()
                    for (approvalCall in approvalCalls) {
                        emit(AgentEvent.ApprovalWaiting(approvalCall))
                        val approvalStarted = nanoTime()
                        val hunkDecision = try {
                            approvals.request(approvalCall).also {
                                emit(AgentEvent.ApprovalFinished(approvalCall, elapsedMillis(approvalStarted), it))
                            }
                        } catch (error: Throwable) {
                            emit(AgentEvent.ApprovalFinished(approvalCall, elapsedMillis(approvalStarted), null))
                            throw error
                        }
                        if (hunkDecision == ApprovalDecision.APPROVE) {
                            approvedHunks += approvalCall
                        } else {
                            approved = false
                            break
                        }
                    }
                    when {
                        approved -> Unit
                        approvedHunks.isNotEmpty() -> executionCall = DiffHunkApproval.collapse(approvedHunks)
                        else -> rejectedAll = true
                    }
                }
                if (rejectedAll) {
                    pendingToolCalls.clear()
                    checkpoints.save(snapshot())
                    messages += AgentMessage(MessageRole.TOOL, "Tool call rejected by user", call.id)
                    checkpoints.save(snapshot())
                    return
                }
            }

            pendingToolCalls.clear()
            pendingToolCalls += PendingToolCall(executionCall, ToolExecutionStage.AWAITING_EXECUTION)
            checkpoints.save(snapshot())
            pendingToolCalls.clear()
            pendingToolCalls += PendingToolCall(executionCall, ToolExecutionStage.RUNNING)
            checkpoints.save(snapshot())
            emit(AgentEvent.ToolStarted(executionCall.id, executionCall.name))
            val toolStarted = nanoTime()
            val result = try {
                tools.execute(executionCall).also {
                    emit(AgentEvent.ToolFinished(executionCall.id, executionCall.name, elapsedMillis(toolStarted), true))
                }
            } catch (error: Throwable) {
                emit(AgentEvent.ToolFinished(executionCall.id, executionCall.name, elapsedMillis(toolStarted), false))
                throw error
            }
            pendingToolCalls.clear()
            checkpoints.save(snapshot())
            messages += AgentMessage(MessageRole.TOOL, result, executionCall.id)
            checkpoints.save(snapshot())
        }

        while (pendingToolCalls.isNotEmpty()) {
            if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", snapshot())
            val pending = pendingToolCalls.removeFirst()
            executePending(
                pending.call,
                approvedByResume = pending.stage != ToolExecutionStage.AWAITING_APPROVAL,
            )
        }

        while (round < limits.maxRounds) {
            if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", snapshot())
            val modelRound = round + 1
            emit(AgentEvent.ModelStarted(modelRound))
            val modelStarted = nanoTime()
            val reply = try {
                if (streamingModel == null) {
                    model.complete(messages)
                } else {
                    streamingModel.completeStreaming(messages) { text ->
                        if (text.isNotEmpty()) emit(AgentEvent.ModelDelta(text))
                    }
                }
            } catch (error: Throwable) {
                emit(AgentEvent.ModelFinished(modelRound, elapsedMillis(modelStarted), false))
                throw error
            }
            emit(AgentEvent.ModelFinished(modelRound, elapsedMillis(modelStarted), true))
            round += 1
            consumedTokens += reply.inputTokens + reply.outputTokens
            if (consumedTokens > limits.maxTokens) return AgentResult.Stopped("token_budget_exceeded", snapshot())

            if (reply.content.isNotBlank() || reply.toolCalls.isNotEmpty()) {
                messages += AgentMessage(
                    role = MessageRole.ASSISTANT,
                    content = reply.content,
                    toolCalls = reply.toolCalls,
                )
            }
            if (reply.toolCalls.isEmpty()) {
                val checkpoint = snapshot()
                checkpoints.save(checkpoint)
                return AgentResult.Completed(reply.content, checkpoint)
            }

            for (call in reply.toolCalls) {
                if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", snapshot())
                if (++toolCallCount > limits.maxToolCalls) return AgentResult.Stopped("tool_budget_exceeded", snapshot())
                pendingToolCalls.clear()
                pendingToolCalls += PendingToolCall(call, ToolExecutionStage.AWAITING_APPROVAL)
                checkpoints.save(snapshot())
                executePending(call, approvedByResume = false)
            }
        }
        return AgentResult.Stopped("round_limit_exceeded", snapshot())
    }
}
