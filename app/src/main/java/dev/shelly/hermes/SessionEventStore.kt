package dev.shelly.hermes

import android.content.Context
import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.MessageRole
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

enum class SessionEventType {
    SESSION_STARTED,
    CHECKPOINT,
    STATUS,
    MODEL_STARTED,
    MODEL_FINISHED,
    APPROVAL_WAITING,
    APPROVAL_FINISHED,
    TOOL_STARTED,
    TOOL_FINISHED,
    FORKED,
    MIGRATED_CHECKPOINT,
}

data class SessionEvent(
    val type: SessionEventType,
    val detail: String = "",
    val checkpoint: AgentCheckpoint? = null,
    val sourceSessionId: String? = null,
    val sourceSequence: Long? = null,
)

data class SessionEventEnvelope(
    val sessionId: String,
    val sequence: Long,
    val timestamp: Long,
    val event: SessionEvent,
)

class SessionEventCorruptionException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

/** Crash-safe, app-private JSONL event log used as the durable source for Android sessions. */
class SessionEventStore(
    private val directory: File,
    val sessionId: String,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    constructor(context: Context, sessionId: String) :
        this(File(context.filesDir, DIRECTORY_NAME), sessionId)

    private val file = File(directory, "${fileKey(sessionId)}.jsonl")
    private val lock = locks.computeIfAbsent(file.absolutePath) { Any() }

    init {
        require(sessionId.isNotBlank()) { "sessionId must not be blank" }
        check(directory.exists() || directory.mkdirs()) {
            "Unable to create session event directory: $directory"
        }
    }

    fun append(event: SessionEvent): SessionEventEnvelope = synchronized(lock) {
        val previousSequence = nextSequences[file.absolutePath] ?: run {
            loadLocked().lastOrNull()?.sequence ?: 0L
        }
        require(previousSequence < MAX_EVENTS) { "Session event limit exceeded" }
        val envelope = SessionEventEnvelope(
            sessionId = sessionId,
            sequence = previousSequence + 1L,
            timestamp = clock(),
            event = event,
        )
        val line = (SessionEventCodec.encode(envelope) + "\n")
            .toByteArray(StandardCharsets.UTF_8)
        val previousLength = file.takeIf { it.isFile }?.length() ?: 0L
        require(previousLength + line.size <= MAX_FILE_BYTES) { "Session event log is too large" }
        try {
            FileOutputStream(file, true).use { output ->
                output.write(line)
                output.fd.sync()
            }
        } catch (error: Throwable) {
            runCatching { RandomAccessFile(file, "rw").use { it.setLength(previousLength) } }
            throw error
        }
        nextSequences[file.absolutePath] = envelope.sequence
        envelope
    }

    fun load(): List<SessionEventEnvelope> = synchronized(lock) { loadLocked() }

    fun latestCheckpoint(throughSequence: Long = Long.MAX_VALUE): AgentCheckpoint? =
        load().asSequence()
            .takeWhile { it.sequence <= throughSequence }
            .mapNotNull { it.event.checkpoint }
            .lastOrNull()

    fun hasCheckpoint(): Boolean = latestCheckpoint() != null

    fun deriveMessages(throughSequence: Long = Long.MAX_VALUE): List<AgentMessage> =
        latestCheckpoint(throughSequence)?.messages.orEmpty()

    fun fork(newSessionId: String, throughSequence: Long): SessionEventStore {
        require(throughSequence > 0L) { "throughSequence must be positive" }
        val checkpoint = latestCheckpoint(throughSequence)
            ?: throw IllegalArgumentException("No checkpoint exists at or before event $throughSequence")
        val fork = SessionEventStore(directory, newSessionId, clock)
        check(fork.load().isEmpty()) { "Target session already exists: $newSessionId" }
        fork.append(
            SessionEvent(
                type = SessionEventType.FORKED,
                sourceSessionId = sessionId,
                sourceSequence = throughSequence,
            ),
        )
        fork.append(SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint))
        return fork
    }

    private fun loadLocked(): List<SessionEventEnvelope> {
        if (!file.isFile) return emptyList()
        if (file.length() > MAX_FILE_BYTES) {
            throw SessionEventCorruptionException("Session event log is too large")
        }
        val lines = file.readLines(StandardCharsets.UTF_8).filter { it.isNotBlank() }
        return lines.mapIndexed { index, line ->
            val record = try {
                SessionEventCodec.decode(line)
            } catch (error: Throwable) {
                throw SessionEventCorruptionException(
                    "Invalid session event JSON at line ${index + 1}",
                    error,
                )
            }
            val expected = index.toLong() + 1L
            if (record.sessionId != sessionId || record.sequence != expected || record.timestamp < 0L) {
                throw SessionEventCorruptionException("Invalid session event envelope at sequence $expected")
            }
            record
        }
    }

    companion object {
        private const val DIRECTORY_NAME = "session-events"
        private const val MAX_EVENTS = 10_000
        private const val MAX_FILE_BYTES = 32L * 1024L * 1024L
        private val locks = ConcurrentHashMap<String, Any>()
        private val nextSequences = ConcurrentHashMap<String, Long>()

        fun clearAll(context: Context) {
            val directory = File(context.filesDir, DIRECTORY_NAME)
            directory.listFiles()?.forEach { file ->
                nextSequences.remove(file.absolutePath)
                file.delete()
            }
        }

        private fun fileKey(sessionId: String): String = MessageDigest.getInstance("SHA-256")
            .digest(sessionId.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }
}

object SessionEventCodec {
    private const val FORMAT_VERSION = 1

    fun encode(envelope: SessionEventEnvelope): String = JSONObject().apply {
        put("version", FORMAT_VERSION)
        put("sessionId", envelope.sessionId)
        put("sequence", envelope.sequence)
        put("timestamp", envelope.timestamp)
        put("type", envelope.event.type.name)
        put("detail", envelope.event.detail)
        envelope.event.sourceSessionId?.let { put("sourceSessionId", it) }
        envelope.event.sourceSequence?.let { put("sourceSequence", it) }
        envelope.event.checkpoint?.let { put("checkpoint", encodeCheckpoint(it)) }
    }.toString()

    fun decode(value: String): SessionEventEnvelope {
        val json = JSONObject(value)
        require(json.getInt("version") == FORMAT_VERSION) { "Unsupported event format" }
        val checkpoint = json.optJSONObject("checkpoint")?.let(::decodeCheckpoint)
        return SessionEventEnvelope(
            sessionId = json.getString("sessionId"),
            sequence = json.getLong("sequence"),
            timestamp = json.getLong("timestamp"),
            event = SessionEvent(
                type = SessionEventType.valueOf(json.getString("type")),
                detail = json.optString("detail", ""),
                checkpoint = checkpoint,
                sourceSessionId = json.optString("sourceSessionId").takeIf { it.isNotBlank() },
                sourceSequence = if (json.has("sourceSequence")) json.getLong("sourceSequence") else null,
            ),
        )
    }

    private fun encodeCheckpoint(checkpoint: AgentCheckpoint): JSONObject = JSONObject().apply {
        put("round", checkpoint.round)
        put("consumedTokens", checkpoint.consumedTokens)
        put("toolCalls", checkpoint.toolCalls)
        put("messages", JSONArray().apply {
            checkpoint.messages.forEach { message ->
                put(JSONObject().apply {
                    put("role", message.role.name)
                    put("content", message.content)
                    message.toolCallId?.let { put("toolCallId", it) }
                })
            }
        })
    }

    private fun decodeCheckpoint(json: JSONObject): AgentCheckpoint {
        val messagesJson = json.getJSONArray("messages")
        require(messagesJson.length() <= 100_000) { "Too many checkpoint messages" }
        val messages = buildList {
            for (index in 0 until messagesJson.length()) {
                val message = messagesJson.getJSONObject(index)
                add(
                    AgentMessage(
                        role = MessageRole.valueOf(message.getString("role")),
                        content = message.getString("content"),
                        toolCallId = message.optString("toolCallId").takeIf { it.isNotBlank() },
                    ),
                )
            }
        }
        return AgentCheckpoint(
            messages = messages,
            round = json.getInt("round").also { require(it >= 0) },
            consumedTokens = json.getInt("consumedTokens").also { require(it >= 0) },
            toolCalls = json.getInt("toolCalls").also { require(it >= 0) },
        )
    }
}
