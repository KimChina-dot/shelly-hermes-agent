package dev.shelly.hermes.core

interface CancellationSignal {
    val isCancelled: Boolean
}

fun interface ModelGateway {
    suspend fun complete(messages: List<AgentMessage>): ModelReply
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

sealed interface AgentResult {
    data class Completed(val message: String, val checkpoint: AgentCheckpoint) : AgentResult
    data class Stopped(val reason: String, val checkpoint: AgentCheckpoint) : AgentResult
}

class AgentCore(
    private val model: ModelGateway,
    private val tools: ToolExecutor,
    private val approvals: ApprovalGateway,
    private val checkpoints: CheckpointStore,
    private val limits: AgentLimits = AgentLimits()
) {
    suspend fun run(
        initialMessages: List<AgentMessage>,
        cancellation: CancellationSignal
    ): AgentResult {
        val messages = initialMessages.toMutableList()
        var round = 0
        var consumedTokens = 0
        var toolCallCount = 0

        fun snapshot() = AgentCheckpoint(messages.toList(), round, consumedTokens, toolCallCount)

        while (round < limits.maxRounds) {
            if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", snapshot())
            val reply = model.complete(messages)
            round += 1
            consumedTokens += reply.inputTokens + reply.outputTokens
            if (consumedTokens > limits.maxTokens) return AgentResult.Stopped("token_budget_exceeded", snapshot())

            if (reply.content.isNotBlank()) {
                messages += AgentMessage(MessageRole.ASSISTANT, reply.content)
            }
            if (reply.toolCalls.isEmpty()) {
                val checkpoint = snapshot()
                checkpoints.save(checkpoint)
                return AgentResult.Completed(reply.content, checkpoint)
            }

            for (call in reply.toolCalls) {
                if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", snapshot())
                if (++toolCallCount > limits.maxToolCalls) return AgentResult.Stopped("tool_budget_exceeded", snapshot())
                val result = when (approvals.request(call)) {
                    ApprovalDecision.APPROVE -> tools.execute(call)
                    ApprovalDecision.REJECT -> "Tool call rejected by user"
                }
                messages += AgentMessage(MessageRole.TOOL, result, call.id)
                checkpoints.save(snapshot())
            }
        }
        return AgentResult.Stopped("round_limit_exceeded", snapshot())
    }
}
