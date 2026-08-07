package dev.shelly.hermes

/** Stable async boundary consumed by the embedded ES2022 runtime. Never invoke on the UI thread. */
interface AndroidHostBindings {
    suspend fun readText(path: String): String?
    suspend fun exists(path: String): Boolean
    suspend fun writeTextAtomic(path: String, text: String)
    suspend fun appendText(path: String, text: String)
    suspend fun runProcess(executable: String, argv: List<String>, cwd: String?, timeoutMs: Long, outputLimit: Int): ProcessResult
    suspend fun scheduleTask(taskId: String, payloadJson: String)
    suspend fun cancelTask(taskId: String)
    suspend fun notify(event: HostNotification)
}
data class ProcessResult(val exitCode: Int, val stdout: String, val stderr: String, val timedOut: Boolean, val truncated: Boolean)
data class HostNotification(val eventId: String, val kind: Kind, val title: String, val progress: Int? = null) { enum class Kind { PROGRESS, COMPLETION, ERROR } }

object LogicalPath {
    fun validate(value: String): String { require(value.isNotBlank() && !value.startsWith('/') && '\u0000' !in value); require(value.replace('\\', '/').split('/').none { it == ".." }); return value }
}
