package dev.shelly.hermes

import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** Long-running shell sessions that the agent can start, poll, and cancel. */
class ShellSessionManager(
    private val workingDirectory: File,
    private val shellPath: String = detectShellPath(),
) {
    companion object {
        private const val MAX_COMMAND_LENGTH = 4_096
        private const val MAX_SESSION_MILLIS = 2 * 60_000L

        fun detectShellPath(): String {
            val candidates = listOf("/system/bin/sh", "/bin/sh")
            return candidates.firstOrNull { File(it).canExecute() } ?: "/bin/sh"
        }
    }

    private class Session(
        val id: String,
        val command: String,
        val process: Process,
        val stdout = StringBuilder(),
        val stderr = StringBuilder(),
        val startedAt: Long = System.currentTimeMillis(),
    )

    private val sessions = ConcurrentHashMap<String, Session>()
    private val counter = AtomicLong(0)
    private val readerPool = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "shell-session-reader").apply { isDaemon = true }
    }

    fun start(command: String): String {
        require(command.isNotBlank()) { "Command must not be blank" }
        require(command.length <= MAX_COMMAND_LENGTH) { "Command exceeds $MAX_COMMAND_LENGTH characters" }
        val process = ProcessBuilder(shellPath, "-c", command)
            .directory(workingDirectory)
            .redirectErrorStream(false)
            .start()
        val id = "sess-" + counter.incrementAndGet()
        val session = Session(id, command, process)
        sessions[id] = session
        readerPool.execute { drain(id, process.inputStream, session.stdout) }
        readerPool.execute { drain(id, process.errorStream, session.stderr) }
        expireOldSessions()
        return id
    }

    fun poll(sessionId: String): String {
        val session = sessions[sessionId] ?: return JSONObject()
            .put("session_id", sessionId)
            .put("exists", false)
            .toString()
        val running = session.process.isAlive
        val exit = if (running) null else session.process.exitValue()
        val stdout = session.stdout.toString()
        val stderr = session.stderr.toString()
        session.stdout.setLength(0)
        session.stderr.setLength(0)
        return JSONObject()
            .put("session_id", sessionId)
            .put("exists", true)
            .put("running", running)
            .put("exit_code", if (exit == null) JSONObject.NULL else exit)
            .put("stdout", stdout)
            .put("stderr", stderr)
            .toString()
    }

    fun cancel(sessionId: String): String {
        val session = sessions[sessionId] ?: return JSONObject()
            .put("session_id", sessionId)
            .put("exists", false)
            .put("cancelled", false)
            .toString()
        runCatching { session.process.destroy() }
        runCatching { session.process.destroyForcibly() }
        sessions.remove(sessionId)
        return JSONObject()
            .put("session_id", sessionId)
            .put("exists", true)
            .put("cancelled", true)
            .toString()
    }

    fun sessions(): List<String> = sessions.values.sortedByDescending { it.startedAt }.map { it.id }

    fun shutdown() {
        sessions.values.forEach { session -> runCatching { session.process.destroyForcibly() } }
        sessions.clear()
        readerPool.shutdownNow()
    }

    private fun drain(sessionId: String, stream: java.io.InputStream, output: StringBuilder) {
        try {
            stream.bufferedReader(Charsets.UTF_8).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    synchronized(output) {
                        if (output.length + line.length + 1 <= MAX_OUTPUT_PER_SESSION) {
                            output.appendLine(line)
                        }
                    }
                }
            }
        } catch (_: Throwable) {
            // Reader can race with destroy; session state is already authoritative.
        }
    }

    private fun expireOldSessions() {
        val now = System.currentTimeMillis()
        sessions.values.forEach { session ->
            if (now - session.startedAt > MAX_SESSION_MILLIS) {
                runCatching { session.process.destroyForcibly() }
                sessions.remove(session.id)
            }
        }
    }

    private companion object {
        const val MAX_OUTPUT_PER_SESSION = 64_000
    }
}
