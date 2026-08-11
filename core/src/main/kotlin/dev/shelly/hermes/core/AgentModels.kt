package dev.shelly.hermes.core

enum class MessageRole { SYSTEM, USER, ASSISTANT, TOOL }

data class AgentMessage(
    val role: MessageRole,
    val content: String,
    val toolCallId: String? = null
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
    val toolCalls: Int
)
