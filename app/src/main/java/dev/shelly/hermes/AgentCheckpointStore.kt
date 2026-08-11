package dev.shelly.hermes

import android.content.Context
import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.CheckpointStore
import dev.shelly.hermes.core.MessageRole
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
                require(input.readInt() == FORMAT_VERSION) { "Unsupported checkpoint format" }
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
                    AgentMessage(role, content, toolCallId)
                }
                AgentCheckpoint(messages, round, consumedTokens, toolCalls)
            }
        }.getOrNull()
    }

    companion object {
        private const val DIRECTORY_NAME = "agent-checkpoints"
        private const val FILE_NAME = "latest.checkpoint"
        private const val FORMAT_VERSION = 1
        private const val MAX_MESSAGES = 100_000
    }
}
