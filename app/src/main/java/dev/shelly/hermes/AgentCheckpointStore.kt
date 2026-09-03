package dev.shelly.hermes

import android.content.Context
import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.CheckpointStore
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.PendingToolCall
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolExecutionStage
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.UUID

/** Android file-backed persistence for the latest agent checkpoint. */
class AgentCheckpointStore(private val directory: File) : CheckpointStore {
    constructor(context: Context) : this(File(context.filesDir, DIRECTORY_NAME))

    init {
        check(directory.exists() || directory.mkdirs()) {
            "Unable to create checkpoint directory: $directory"
        }
    }

    override suspend fun save(checkpoint: AgentCheckpoint) {
        val temporary = File(directory, ".${UUID.randomUUID()}.tmp")
        val target = File(directory, FILE_NAME)
        try {
            DataOutputStream(FileOutputStream(temporary).buffered()).use { output ->
                output.writeInt(FORMAT_VERSION)
                output.writeInt(checkpoint.round)
                output.writeInt(checkpoint.consumedTokens)
                output.writeInt(checkpoint.toolCalls)
                output.writeInt(checkpoint.messages.size)
                checkpoint.messages.forEach { message ->
                    output.writeInt(message.role.ordinal)
                    output.writeUTF(message.content)
                    output.writeBoolean(message.toolCallId != null)
                    message.toolCallId?.let(output::writeUTF)
                    output.writeInt(message.toolCalls.size)
                    message.toolCalls.forEach { call -> writeToolCall(output, call) }
                }
                output.writeInt(checkpoint.pendingToolCalls.size)
                checkpoint.pendingToolCalls.forEach { pending ->
                    output.writeUTF(pending.stage.name)
                    writeToolCall(output, pending.call)
                }
            }
            if (target.exists() && !target.delete()) {
                error("Unable to replace checkpoint: $target")
            }
            check(temporary.renameTo(target)) {
                "Unable to commit checkpoint: $target"
            }
        } finally {
            temporary.delete()
        }
    }

    /** Returns the last valid checkpoint, or null when none exists or data is unreadable. */
    fun load(): AgentCheckpoint? {
        val source = File(directory, FILE_NAME)
        if (!source.isFile) return null
        return runCatching {
            DataInputStream(FileInputStream(source).buffered()).use { input ->
                val version = input.readInt()
                require(version in 1..FORMAT_VERSION) { "Unsupported checkpoint format" }
                val round = input.readInt()
                val consumedTokens = input.readInt()
                val toolCalls = input.readInt()
                val messageCount = input.readInt()
                require(round >= 0 && consumedTokens >= 0 && toolCalls >= 0)
                require(messageCount in 0..MAX_MESSAGES)
                val messages = List(messageCount) {
                    val roleOrdinal = input.readInt()
                    val role = MessageRole.entries.getOrNull(roleOrdinal)
                        ?: error("Unknown message role: $roleOrdinal")
                    val content = input.readUTF()
                    val toolCallId = if (input.readBoolean()) input.readUTF() else null
                    val messageToolCalls = if (version >= 2) {
                        List(input.readInt()) { readToolCall(input) }
                    } else {
                        emptyList()
                    }
                    AgentMessage(role, content, toolCallId, messageToolCalls)
                }
                val pending = if (version >= 2) {
                    List(input.readInt()) {
                        PendingToolCall(
                            call = readToolCall(input),
                            stage = ToolExecutionStage.valueOf(input.readUTF()),
                        )
                    }
                } else {
                    emptyList()
                }
                AgentCheckpoint(messages, round, consumedTokens, toolCalls, pending)
            }
        }.getOrNull()
    }

    fun hasCheckpoint(): Boolean = load() != null

    private fun writeToolCall(output: DataOutputStream, call: ToolCall) {
        output.writeUTF(call.id)
        output.writeUTF(call.name)
        output.writeUTF(call.argumentsJson)
    }

    private fun readToolCall(input: DataInputStream): ToolCall = ToolCall(
        id = input.readUTF(),
        name = input.readUTF(),
        argumentsJson = input.readUTF(),
    )

    companion object {
        private const val DIRECTORY_NAME = "agent-checkpoints"
        private const val FILE_NAME = "latest.checkpoint"
        private const val FORMAT_VERSION = 2
        private const val MAX_MESSAGES = 100_000
    }
}
