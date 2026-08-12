package dev.shelly.hermes

import dev.shelly.hermes.core.AgentCore
import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.AgentResult
import dev.shelly.hermes.core.CancellationSignal
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

/**
 * Android-side lifecycle coordinator for [AgentCore].
 *
 * The coordinator deliberately depends on small host callbacks instead of Android framework
 * classes so task execution can be tested without a device. The application/service layer owns
 * notification creation and calls [onForegroundServiceStopped] when Android destroys the service.
 */
class AgentCoreAndroidCoordinator(
    private val agentFactory: (taskId: String) -> AgentCore,
    private val foregroundService: ForegroundServiceConnection,
    private val listener: TaskStateListener,
    private val executor: Executor = Executors.newCachedThreadPool()
) {
    private val tasks = ConcurrentHashMap<String, RunningTask>()

    /** Starts a task once. Returns false when the same task id is already active. */
    fun start(taskId: String, messages: List<AgentMessage>, resumeFrom: AgentCheckpoint? = null): Boolean {
        require(taskId.isNotBlank()) { "taskId must not be blank" }

        val task = RunningTask(taskId)
        if (tasks.putIfAbsent(taskId, task) != null) return false

        publish(taskId, TaskState.STARTING)
        foregroundService.start(taskId)

        executor.execute {
            publish(taskId, if (task.cancelled.get()) task.state else TaskState.RUNNING)
            val block: suspend () -> AgentResult = {
                agentFactory(taskId).run(messages, task, resumeFrom)
            }
            block.startCoroutine(object : Continuation<AgentResult> {
                override val context = EmptyCoroutineContext

                override fun resumeWith(result: Result<AgentResult>) {
                    result.fold(
                        onSuccess = { finish(task, it) },
                        onFailure = { fail(task, it) }
                    )
                }
            })
        }
        return true
    }

    /** Requests a cooperative stop. AgentCore observes this through CancellationSignal. */
    fun stop(taskId: String): Boolean = signal(taskId, TaskState.STOPPING)

    /** Requests user cancellation. This uses the same cooperative signal with distinct UI state. */
    fun cancel(taskId: String): Boolean = signal(taskId, TaskState.CANCELLING)

    fun state(taskId: String): TaskState? = tasks[taskId]?.state

    fun activeTaskIds(): Set<String> = tasks.keys.toSet()

    /** Called by the foreground service from onDestroy/onTaskRemoved. */
    fun onForegroundServiceStopped(taskId: String) {
        signal(taskId, TaskState.CANCELLING)
    }

    private fun signal(taskId: String, state: TaskState): Boolean {
        val task = tasks[taskId] ?: return false
        if (!task.cancelled.compareAndSet(false, true)) return false
        publish(taskId, state)
        foregroundService.update(taskId, state)
        return true
    }

    private fun finish(task: RunningTask, result: AgentResult) {
        if (!tasks.remove(task.taskId, task)) return
        val finalState = when (result) {
            is AgentResult.Completed -> TaskState.COMPLETED
            is AgentResult.Stopped -> TaskState.STOPPED
        }
        task.state = finalState
        foregroundService.update(task.taskId, finalState)
        foregroundService.stop(task.taskId)
        listener.onStateChanged(TaskStatus(task.taskId, finalState, result = result))
    }

    private fun fail(task: RunningTask, error: Throwable) {
        if (!tasks.remove(task.taskId, task)) return
        task.state = TaskState.FAILED
        foregroundService.update(task.taskId, TaskState.FAILED)
        foregroundService.stop(task.taskId)
        listener.onStateChanged(TaskStatus(task.taskId, TaskState.FAILED, error = error))
    }

    private fun publish(taskId: String, state: TaskState) {
        tasks[taskId]?.state = state
        listener.onStateChanged(TaskStatus(taskId, state))
    }

    private class RunningTask(
        val taskId: String,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        @Volatile var state: TaskState = TaskState.STARTING
    ) : CancellationSignal {
        override val isCancelled: Boolean
            get() = cancelled.get()
    }
}

enum class TaskState {
    STARTING,
    RUNNING,
    STOPPING,
    CANCELLING,
    COMPLETED,
    STOPPED,
    FAILED
}

data class TaskStatus(
    val taskId: String,
    val state: TaskState,
    val result: AgentResult? = null,
    val error: Throwable? = null
)

fun interface TaskStateListener {
    fun onStateChanged(status: TaskStatus)
}

/** Adapter implemented by TaskForegroundService or its application-scoped controller. */
interface ForegroundServiceConnection {
    fun start(taskId: String)
    fun update(taskId: String, state: TaskState)
    fun stop(taskId: String)
}
