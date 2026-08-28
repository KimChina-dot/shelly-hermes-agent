package dev.shelly.hermes.core

enum class MessageRole { SYSTEM, USER, ASSISTANT, TOOL }

data class AgentMessage(
    val role: MessageRole,
    val content: String,
    val toolCallId: String? = null,
    val toolCalls: List<ToolCall> = emptyList()
)

data class ToolCall(
    val id: String,
    val name: String,
    val argumentsJson: String
)

data class ModelReply(
    val content: String = "",
    val toolCalls: List<ToolCall> = emptyList(),
    val inputTokens: Int = 0,
    val outputTokens: Int = 0
)

data class AgentLimits(
    val maxRounds: Int = 16,
    val maxTokens: Int = 64_000,
    val maxToolCalls: Int = 32
)

data class AgentCheckpoint(
    val messages: List<AgentMessage>,
    val round: Int,
    val consumedTokens: Int,
    val toolCalls: Int,
    val pendingToolCalls: List<PendingToolCall> = emptyList(),
)

/** Durable execution queue used to restore a task after Android kills the process. */
data class PendingToolCall(
    val call: ToolCall,
    val stage: ToolExecutionStage,
)

enum class ToolExecutionStage { AWAITING_APPROVAL, AWAITING_EXECUTION, RUNNING }

/** Lightweight lifecycle signals for progress UI, metrics, and diagnostics. */
sealed interface AgentEvent {
    data class ModelStarted(val round: Int) : AgentEvent

    data class ModelDelta(val text: String) : AgentEvent

    data class ModelFinished(
        val round: Int,
        val durationMillis: Long,
        val succeeded: Boolean
    ) : AgentEvent

    data class ApprovalWaiting(val call: ToolCall) : AgentEvent

    data class ApprovalFinished(
        val call: ToolCall,
        val durationMillis: Long,
        val decision: ApprovalDecision?
    ) : AgentEvent

    data class ToolStarted(
        val toolCallId: String,
        val toolName: String,
        val argumentsJson: String = "",
    ) : AgentEvent

    data class ToolFinished(
        val toolCallId: String,
        val toolName: String,
        val durationMillis: Long,
        val succeeded: Boolean,
        val result: String? = null,
    ) : AgentEvent
}
