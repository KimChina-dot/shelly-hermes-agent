package dev.shelly.hermes

import android.content.Context
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.UUID

data class Session(
    val id: String,
    val prompt: String,
    val updatedAt: Long,
    val status: String = "",
    val summary: String = "",
)

/** Versioned, newline-safe on-disk representation with support for legacy three-line sessions. */
object SessionCodec {
    private const val HEADER = "LUMA_SESSION_V2"
    private val encoder = Base64.getUrlEncoder().withoutPadding()
    private val decoder = Base64.getUrlDecoder()

    fun encode(session: Session): String = listOf(
        HEADER,
        encodeText(session.id),
        session.updatedAt.toString(),
        encodeText(session.prompt),
        encodeText(session.status),
        encodeText(session.summary),
    ).joinToString("\n")

    fun decode(value: String): Session {
        val lines = value.split("\n")
        return if (lines.firstOrNull()?.trimEnd('\r') == HEADER) {
            require(lines.size >= 6) { "Incomplete session record" }
            Session(
                id = decodeText(lines[1].trimEnd('\r')),
                updatedAt = lines[2].trimEnd('\r').toLong(),
                prompt = decodeText(lines[3].trimEnd('\r')),
                status = decodeText(lines[4].trimEnd('\r')),
                summary = decodeText(lines[5].trimEnd('\r')),
            )
        } else {
            val legacy = value.split("\n", limit = 3)
            require(legacy.size == 3) { "Incomplete legacy session record" }
            Session(
                id = legacy[0].trimEnd('\r'),
                updatedAt = legacy[1].trimEnd('\r').toLong(),
                prompt = legacy[2].trimEnd('\r'),
            )
        }
    }

    private fun encodeText(value: String): String =
        encoder.encodeToString(value.toByteArray(StandardCharsets.UTF_8))

    private fun decodeText(value: String): String =
        String(decoder.decode(value), StandardCharsets.UTF_8)
}

/** Pure retention policy kept separate from Android storage so it is cheap to unit test. */
object SessionRetention {
    const val DEFAULT_LIMIT = 100

    fun keepRecent(sessions: Iterable<Session>, limit: Int = DEFAULT_LIMIT): List<Session> {
        require(limit >= 0) { "limit must not be negative" }
        return sessions
            .groupBy { it.id }
            .values
            .map { versions -> versions.maxByOrNull { it.updatedAt }!! }
            .sortedWith(compareByDescending<Session> { it.updatedAt }.thenBy { it.id })
            .take(limit)
    }
}

interface SessionStore {
    fun save(session: Session)
    fun list(): List<Session>
    fun clear()
}

class FileSessionStore(context: Context) : SessionStore {
    private val dir = File(context.filesDir, "sessions").apply { mkdirs() }

    @Synchronized
    override fun save(session: Session) {
        val target = File(dir, "${safe(session.id)}.session")
        val previous = target.takeIf { it.isFile }?.let { file ->
            runCatching { SessionCodec.decode(file.readText()) }.getOrNull()
        }
        val merged = merge(previous, session)
        val tmp = File(dir, ".${UUID.randomUUID()}.tmp")
        try {
            tmp.writeText(SessionCodec.encode(merged))
            try {
                Files.move(
                    tmp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
        prune()
    }

    @Synchronized
    override fun list(): List<Session> = readSessionFiles()
        .mapNotNull { file -> runCatching { SessionCodec.decode(file.readText()) }.getOrNull() }
        .let { sessions -> SessionRetention.keepRecent(sessions) }

    @Synchronized
    override fun clear() {
        readSessionFiles().forEach(File::delete)
    }

    private fun merge(previous: Session?, incoming: Session): Session {
        if (previous == null) return incoming
        // Compatibility with the original caller, which saved a prompt first and later wrote
        // a status label through the old three-argument Session constructor.
        if (incoming.status.isBlank() && incoming.summary.isBlank()) {
            val inferredStatus = incoming.prompt
                .substringAfterLast('：', incoming.prompt)
                .trim()
            return previous.copy(status = inferredStatus, updatedAt = incoming.updatedAt)
        }
        return incoming.copy(
            prompt = incoming.prompt.ifBlank { previous.prompt },
            status = incoming.status.ifBlank { previous.status },
            summary = incoming.summary.ifBlank { previous.summary },
        )
    }

    private fun prune() {
        val recordsById = readSessionFiles().mapNotNull { file ->
            runCatching { SessionCodec.decode(file.readText()) to file }.getOrNull()
        }.associateBy { it.first.id }
        val retainedIds = SessionRetention.keepRecent(recordsById.values.map { it.first })
            .mapTo(mutableSetOf()) { it.id }
        recordsById.filterKeys { it !in retainedIds }.values.forEach { it.second.delete() }
    }

    private fun readSessionFiles(): List<File> =
        dir.listFiles { file -> file.isFile && file.extension == "session" }.orEmpty().toList()

    private fun safe(id: String): String {
        require(Regex("[A-Za-z0-9_-]{1,64}").matches(id)) { "Invalid task id" }
        return id
    }
}
