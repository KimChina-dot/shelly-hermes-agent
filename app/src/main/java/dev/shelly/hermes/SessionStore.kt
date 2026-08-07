package dev.shelly.hermes

import android.content.Context
import java.io.File
import java.util.UUID

data class Session(val id: String, val title: String, val updatedAt: Long)
interface SessionStore { fun save(session: Session); fun list(): List<Session> }
class FileSessionStore(context: Context) : SessionStore {
    private val dir = File(context.filesDir, "sessions").apply { mkdirs() }
    override fun save(session: Session) { val target = File(dir, "${safe(session.id)}.session"); val tmp = File(dir, ".${UUID.randomUUID()}.tmp"); tmp.writeText("${session.id}\n${session.updatedAt}\n${session.title}"); check(tmp.renameTo(target)) }
    override fun list() = dir.listFiles { f -> f.extension == "session" }.orEmpty().mapNotNull { runCatching { val p = it.readText().split("\n", limit = 3); Session(p[0], p[2], p[1].toLong()) }.getOrNull() }.sortedByDescending { it.updatedAt }
    private fun safe(id: String): String { require(Regex("[A-Za-z0-9_-]{1,64}").matches(id)); return id }
}
