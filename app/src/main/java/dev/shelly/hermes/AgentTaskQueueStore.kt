package dev.shelly.hermes

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

enum class QueuedTaskAction { START, RESUME, FORK }

enum class QueuedTaskState { PENDING, RUNNING, COMPLETED, FAILED, CANCELLED }

data class QueuedAgentTask(
    val id: String,
    val action: QueuedTaskAction,
    val prompt: String,
    val mode: AgentMode,
    val profileId: String,
    val createdAt: Long,
    val state: QueuedTaskState = QueuedTaskState.PENDING,
    val attempts: Int = 0,
    val sourceSessionId: String? = null,
    val sourceSequence: Long? = null,
    val detail: String = "",
)

class AgentTaskQueueCorruptionException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

/** Atomic app-private queue. Only one task runs on Android; pending work survives process death. */
class AgentTaskQueueStore(
    private val directory: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    constructor(context: Context) : this(File(context.filesDir, DIRECTORY_NAME))

    private val file = File(directory, FILE_NAME)

    init {
        check(directory.exists() || directory.mkdirs()) { "Unable to create task queue directory" }
    }

    @Synchronized
    fun enqueue(task: QueuedAgentTask): QueuedAgentTask {
        validate(task)
        val tasks = loadMutable()
        val existingIndex = tasks.indexOfFirst { it.id == task.id }
        if (existingIndex >= 0) {
            val existing = tasks[existingIndex]
            if (existing.state in TERMINAL_STATES && task.action == QueuedTaskAction.RESUME) {
                val resumed = task.copy(
                    mode = existing.mode,
                    profileId = existing.profileId,
                    state = QueuedTaskState.PENDING,
                    attempts = existing.attempts,
                    createdAt = task.createdAt.takeIf { it > 0L } ?: clock(),
                    detail = "",
                )
                tasks[existingIndex] = resumed
                save(prune(tasks))
                return resumed
            }
            return existing
        }
        require(tasks.count { it.state !in TERMINAL_STATES } < MAX_TASKS) { "Task queue is full" }
        val normalized = task.copy(
            state = QueuedTaskState.PENDING,
            attempts = 0,
            createdAt = task.createdAt.takeIf { it > 0L } ?: clock(),
            detail = "",
        )
        tasks += normalized
        save(prune(tasks))
        return normalized
    }

    @Synchronized
    fun claimNext(): QueuedAgentTask? {
        val tasks = loadMutable()
        val index = tasks.indexOfFirst { it.state == QueuedTaskState.PENDING }
        if (index < 0) return null
        val claimed = tasks[index].copy(
            state = QueuedTaskState.RUNNING,
            attempts = tasks[index].attempts + 1,
            detail = "",
        )
        tasks[index] = claimed
        save(tasks)
        return claimed
    }

    @Synchronized
    fun finish(id: String, state: QueuedTaskState, detail: String = ""): QueuedAgentTask {
        require(state in TERMINAL_STATES) { "Task finish state must be terminal" }
        val tasks = loadMutable()
        val index = tasks.indexOfFirst { it.id == id }
        require(index >= 0) { "Unknown queued task: $id" }
        val updated = tasks[index].copy(state = state, detail = detail.take(MAX_DETAIL_CHARS))
        tasks[index] = updated
        save(prune(tasks))
        return updated
    }

    @Synchronized
    fun cancelPending(id: String): Boolean {
        val tasks = loadMutable()
        val index = tasks.indexOfFirst { it.id == id && it.state == QueuedTaskState.PENDING }
        if (index < 0) return false
        tasks[index] = tasks[index].copy(state = QueuedTaskState.CANCELLED, detail = "cancelled_before_start")
        save(prune(tasks))
        return true
    }

    @Synchronized
    fun retry(id: String): Boolean {
        val tasks = loadMutable()
        val index = tasks.indexOfFirst { it.id == id && it.state in TERMINAL_STATES }
        if (index < 0) return false
        tasks[index] = tasks[index].copy(state = QueuedTaskState.PENDING, detail = "")
        save(tasks)
        return true
    }

    /** Requeues work left RUNNING when the previous process was killed. */
    @Synchronized
    fun recoverInterrupted(): Int {
        val tasks = loadMutable()
        var recovered = 0
        val updated = tasks.map { task ->
            if (task.state == QueuedTaskState.RUNNING) {
                recovered += 1
                task.copy(state = QueuedTaskState.PENDING, detail = "recovered_after_process_restart")
            } else task
        }
        if (recovered > 0) save(updated)
        return recovered
    }

    @Synchronized
    fun list(): List<QueuedAgentTask> = loadMutable().toList()

    @Synchronized
    fun pendingCount(): Int = loadMutable().count { it.state == QueuedTaskState.PENDING }

    @Synchronized
    fun activeCount(): Int = loadMutable().count {
        it.state == QueuedTaskState.PENDING || it.state == QueuedTaskState.RUNNING
    }

    private fun loadMutable(): MutableList<QueuedAgentTask> {
        if (!file.isFile) return mutableListOf()
        if (file.length() > MAX_FILE_BYTES) throw AgentTaskQueueCorruptionException("Task queue is too large")
        return try {
            AgentTaskQueueCodec.decode(file.readText(StandardCharsets.UTF_8))
                .onEach(::validate)
                .toMutableList()
        } catch (error: AgentTaskQueueCorruptionException) {
            throw error
        } catch (error: Throwable) {
            throw AgentTaskQueueCorruptionException("Invalid task queue", error)
        }
    }

    private fun save(tasks: List<QueuedAgentTask>) {
        val temporary = File(directory, ".${UUID.randomUUID()}.tmp")
        try {
            temporary.writeText(AgentTaskQueueCodec.encode(tasks), StandardCharsets.UTF_8)
            FileOutputStream(temporary, true).use { it.fd.sync() }
            try {
                Files.move(
                    temporary.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            temporary.delete()
        }
    }

    private fun prune(tasks: List<QueuedAgentTask>): List<QueuedAgentTask> {
        if (tasks.size <= MAX_TASKS) return tasks
        val active = tasks.filter { it.state !in TERMINAL_STATES }
        val terminal = tasks.filter { it.state in TERMINAL_STATES }
            .sortedByDescending { it.createdAt }
            .take((MAX_TASKS - active.size).coerceAtLeast(0))
            .toSet()
        return tasks.filter { it.state !in TERMINAL_STATES || it in terminal }
    }

    private fun validate(task: QueuedAgentTask) {
        require(task.id.isNotBlank() && task.id.length <= 128) { "Invalid task id" }
        require(task.prompt.length <= MAX_PROMPT_CHARS) { "Task prompt is too long" }
        require(task.profileId.isNotBlank() && task.profileId.length <= 64) { "Invalid profile id" }
        require(task.attempts >= 0) { "Task attempts must not be negative" }
        if (task.action == QueuedTaskAction.START) require(task.prompt.isNotBlank()) { "Task prompt is required" }
        if (task.action == QueuedTaskAction.FORK) {
            require(!task.sourceSessionId.isNullOrBlank()) { "Fork source session is required" }
            require((task.sourceSequence ?: -1L) > 0L) { "Fork source sequence must be positive" }
        }
    }

    companion object {
        private const val DIRECTORY_NAME = "agent-task-queue"
        private const val FILE_NAME = "queue.json"
        private const val MAX_TASKS = 200
        private const val MAX_PROMPT_CHARS = 100_000
        private const val MAX_DETAIL_CHARS = 4_000
        private const val MAX_FILE_BYTES = 8L * 1024L * 1024L
        private val TERMINAL_STATES = setOf(
            QueuedTaskState.COMPLETED,
            QueuedTaskState.FAILED,
            QueuedTaskState.CANCELLED,
        )
    }
}

object AgentTaskQueueCodec {
    private const val VERSION = 1

    fun encode(tasks: List<QueuedAgentTask>): String = JSONObject().apply {
        put("version", VERSION)
        put("tasks", JSONArray().apply { tasks.forEach { put(encodeTask(it)) } })
    }.toString()

    fun decode(value: String): List<QueuedAgentTask> {
        val root = JSONObject(value)
        if (root.getInt("version") != VERSION) {
            throw AgentTaskQueueCorruptionException("Unsupported task queue version")
        }
        val values = root.getJSONArray("tasks")
        require(values.length() <= 10_000) { "Too many queued tasks" }
        val tasks = buildList {
            for (index in 0 until values.length()) add(decodeTask(values.getJSONObject(index)))
        }
        require(tasks.map { it.id }.toSet().size == tasks.size) { "Duplicate queued task ids" }
        return tasks
    }

    private fun encodeTask(task: QueuedAgentTask): JSONObject = JSONObject().apply {
        put("id", task.id)
        put("action", task.action.name)
        put("prompt", task.prompt)
        put("mode", task.mode.name)
        put("profileId", task.profileId)
        put("createdAt", task.createdAt)
        put("state", task.state.name)
        put("attempts", task.attempts)
        task.sourceSessionId?.let { put("sourceSessionId", it) }
        task.sourceSequence?.let { put("sourceSequence", it) }
        put("detail", task.detail)
    }

    private fun decodeTask(json: JSONObject): QueuedAgentTask = QueuedAgentTask(
        id = json.getString("id"),
        action = QueuedTaskAction.valueOf(json.getString("action")),
        prompt = json.getString("prompt"),
        mode = AgentMode.valueOf(json.getString("mode")),
        profileId = json.getString("profileId"),
        createdAt = json.getLong("createdAt").also { require(it >= 0L) },
        state = QueuedTaskState.valueOf(json.getString("state")),
        attempts = json.getInt("attempts").also { require(it >= 0) },
        sourceSessionId = json.optString("sourceSessionId").takeIf { it.isNotBlank() },
        sourceSequence = if (json.has("sourceSequence")) json.getLong("sourceSequence") else null,
        detail = json.optString("detail", ""),
    )
}
