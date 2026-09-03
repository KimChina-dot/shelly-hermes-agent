package dev.shelly.hermes

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import androidx.core.app.NotificationCompat
import dev.shelly.hermes.core.AgentCore
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.AgentResult
import dev.shelly.hermes.core.AgentEvent
import dev.shelly.hermes.core.AgentObserver
import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentBundle
import dev.shelly.hermes.core.AgentBundleOrchestrator
import dev.shelly.hermes.core.AgentProfile
import dev.shelly.hermes.core.AgentProfileMode
import dev.shelly.hermes.core.AgentProfileRegistry
import dev.shelly.hermes.core.AgentProfileRunner
import dev.shelly.hermes.core.ApprovalDecision
import dev.shelly.hermes.core.CheckpointStore
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.ToolApprovalPolicy
import java.io.File

/** Runs one user-started agent task in a foreground service. */
class TaskForegroundService : Service(), ForegroundServiceConnection, TaskStateListener {
    private lateinit var coordinator: AgentCoreAndroidCoordinator
    private lateinit var queue: AgentTaskQueueStore
    private val profiles = AgentProfileRegistry()
    private var currentTaskId: String? = null
    private var currentMode: AgentMode = AgentMode.ACT
    private var currentProfile: AgentProfile = profiles.requireProfile("coding")
    private var currentBundle: AgentBundle? = null
    @Volatile private var currentModelClient: OpenAiModelGateway? = null
    @Volatile private var currentEventStore: SessionEventStore? = null
    @Volatile private var shellSessions: ShellSessionManager? = null
    @Volatile private var destroying = false

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(CHANNEL, "Luma 任务", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        queue = AgentTaskQueueStore(this)
        runCatching { queue.recoverInterrupted() }

        coordinator = AgentCoreAndroidCoordinator(
            agentFactory = { taskId -> createTaskRunner(taskId) },
            foregroundService = this,
            listener = this,
        )
        ApprovalBridge.gateway.launcher = {
            broadcastStatus(STATE_AWAITING_APPROVAL, "有一项工具操作等待审批")
            showNotification(
                title = "Luma 等待审批",
                text = "点按查看工具调用和变更内容",
                approvalPending = true,
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                currentModelClient?.cancelCurrentRequest()
                currentTaskId?.let(coordinator::cancel)
                return START_NOT_STICKY
            }
            ACTION_CANCEL_QUEUED -> {
                val id = intent.getStringExtra(EXTRA_TASK_ID).orEmpty()
                queue.cancelPending(id)
                broadcastQueueState()
                drainQueue()
                return START_NOT_STICKY
            }
            ACTION_RETRY_QUEUED -> {
                val id = intent.getStringExtra(EXTRA_TASK_ID).orEmpty()
                queue.retry(id)
                broadcastQueueState()
                drainQueue()
                return START_REDELIVER_INTENT
            }
            ACTION_START, ACTION_RESUME, ACTION_FORK_TASK -> Unit
            else -> return START_NOT_STICKY
        }

        try {
            val request = intent.toQueuedTask()
            requireSelection(request.profileId)
            val queued = queue.enqueue(request)
            broadcastStatus(STATE_QUEUED, "任务已进入队列，前方 ${queue.pendingCount() - 1} 项")
            broadcastQueueState()
        } catch (error: Throwable) {
            broadcastStatus(TaskState.FAILED.name, error.message ?: "任务入队失败")
            return START_NOT_STICKY
        }
        drainQueue()
        return START_REDELIVER_INTENT
    }

    @Synchronized
    private fun drainQueue() {
        if (currentTaskId != null) return
        while (true) {
            val task = queue.claimNext() ?: run {
                broadcastQueueState()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            val failure = runCatching { startQueuedTask(task) }.exceptionOrNull()
            if (failure == null) return
            currentTaskId = null
            currentEventStore = null
            currentModelClient = null
            currentBundle = null
            queue.finish(task.id, QueuedTaskState.FAILED, failure.message.orEmpty())
            broadcastStatus(TaskState.FAILED.name, failure.message ?: "任务启动失败")
        }
    }

    private fun startQueuedTask(task: QueuedAgentTask) {
        val isResume = task.action == QueuedTaskAction.RESUME
        val isFork = task.action == QueuedTaskAction.FORK
        val taskId = task.id
        val prompt = task.prompt
        val bundle = task.profileId.takeIf { it.startsWith(BUNDLE_PREFIX) }
            ?.removePrefix(BUNDLE_PREFIX)
            ?.let(profiles::requireBundle)
        val profile = bundle?.defaultProfile ?: profiles.requireProfile(task.profileId)
        val mode = if (profile.mode == AgentProfileMode.ACT) AgentMode.ACT else AgentMode.PLAN
        val eventStore = if (isFork) {
            SessionEventStore(this, requireNotNull(task.sourceSessionId))
                .fork(taskId, requireNotNull(task.sourceSequence))
        } else {
            SessionEventStore(this, taskId)
        }
        val durableCheckpoint = eventStore.latestCheckpoint()
        val resumeCheckpoint = when {
            isFork -> durableCheckpoint ?: error("分支中没有可恢复的 checkpoint")
            isResume -> durableCheckpoint ?: migrateLegacyCheckpoint(eventStore)
            task.action == QueuedTaskAction.START && durableCheckpoint != null -> durableCheckpoint
            else -> null
        }
        if (isResume && resumeCheckpoint == null) error("没有可恢复的 checkpoint")

        currentTaskId = taskId
        currentMode = mode
        currentProfile = profile
        currentBundle = bundle
        currentEventStore = eventStore
        val sessionPrompt = when {
            prompt.isNotBlank() -> prompt.take(120)
            isFork -> sourcePrompt(task.sourceSessionId).let { "$it（分支）" }
            else -> FileSessionStore(this).list().firstOrNull { it.id == taskId }?.prompt ?: "Resumed task"
        }
        FileSessionStore(this).save(Session(taskId, sessionPrompt, System.currentTimeMillis()))
        val initialMessages = if (resumeCheckpoint != null) {
            emptyList()
        } else {
            (if (bundle == null) buildInitialMessages(profile, prompt) else {
                listOf(AgentMessage(MessageRole.USER, prompt))
            }).also { messages ->
                eventStore.append(SessionEvent(SessionEventType.SESSION_STARTED, detail = prompt))
                eventStore.append(
                    SessionEvent(
                        SessionEventType.CHECKPOINT,
                        checkpoint = AgentCheckpoint(messages, 0, 0, 0),
                    ),
                )
            }
        }
        if (!coordinator.start(taskId, initialMessages, resumeCheckpoint)) {
            currentTaskId = null
            currentEventStore = null
            error("任务未能启动")
        }
    }

    private fun Intent.toQueuedTask(): QueuedAgentTask {
        val actionValue = when (action) {
            ACTION_START -> QueuedTaskAction.START
            ACTION_RESUME -> QueuedTaskAction.RESUME
            ACTION_FORK_TASK -> QueuedTaskAction.FORK
            else -> error("不支持的任务动作")
        }
        val mode = AgentMode.fromWireValue(getStringExtra(EXTRA_MODE))
        val profileId = getStringExtra(EXTRA_PROFILE_ID)?.takeIf { it.isNotBlank() }
            ?: if (mode == AgentMode.PLAN) "planner" else "coding"
        return QueuedAgentTask(
            id = getStringExtra(EXTRA_TASK_ID)?.takeIf { it.isNotBlank() } ?: error("缺少任务 ID"),
            action = actionValue,
            prompt = getStringExtra(EXTRA_PROMPT)?.trim().orEmpty(),
            mode = mode,
            profileId = profileId,
            createdAt = System.currentTimeMillis(),
            sourceSessionId = getStringExtra(EXTRA_SOURCE_SESSION_ID),
            sourceSequence = getLongExtra(EXTRA_SOURCE_SEQUENCE, -1L).takeIf { it > 0L },
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        destroying = true
        currentModelClient?.cancelCurrentRequest()
        shellSessions?.shutdown()
        shellSessions = null
        currentTaskId?.let(coordinator::onForegroundServiceStopped)
        super.onDestroy()
    }

    override fun start(taskId: String) {
        showNotification("Luma 正在启动任务", "正在准备模型和工作区")
    }

    override fun update(taskId: String, state: TaskState) {
        showNotification("Luma", stateDescription(state))
    }

    override fun stop(taskId: String) {
        currentModelClient = null
    }

    override fun onStateChanged(status: TaskStatus) {
        val detail = when (val result = status.result) {
            is AgentResult.Completed -> result.message
            is AgentResult.Stopped -> result.reason
            null -> status.error?.message.orEmpty()
        }
        FileSessionStore(this).save(
            Session(
                id = status.taskId,
                prompt = "",
                updatedAt = System.currentTimeMillis(),
                status = status.state.name,
                summary = detail,
            ),
        )
        runCatching {
            currentEventStore?.append(
                SessionEvent(SessionEventType.STATUS, detail = status.state.name + ":" + detail),
            )
        }
        broadcastStatus(status.state.name, detail)
        if (status.state in TERMINAL_TASK_STATES) {
            if (destroying) return
            val queueState = when (status.state) {
                TaskState.COMPLETED -> QueuedTaskState.COMPLETED
                TaskState.STOPPED -> if (detail == "cancelled") QueuedTaskState.CANCELLED else QueuedTaskState.FAILED
                else -> QueuedTaskState.FAILED
            }
            runCatching { queue.finish(status.taskId, queueState, detail) }
            currentTaskId = null
            currentEventStore = null
            currentModelClient = null
            currentBundle = null
            broadcastQueueState()
            drainQueue()
        }
    }

    private fun createTaskRunner(taskId: String): AgentTaskRunner {
        val bundle = currentBundle
        if (bundle == null) {
            val profile = currentProfile
            return AgentTaskRunner { messages, cancellation, resumeFrom ->
                createAgent(taskId, profile).run(messages, cancellation, resumeFrom)
            }
        }
        val checkpoints = checkpointStore(taskId)
        val orchestrator = AgentBundleOrchestrator(
            runner = AgentProfileRunner { profile, messages, cancellation, resumeFrom ->
                broadcastStatus(TaskState.RUNNING.name, "${profile.name} Agent 正在执行")
                createAgent(taskId, profile).run(messages, cancellation, resumeFrom)
            },
            checkpoints = checkpoints,
        )
        return AgentTaskRunner { messages, cancellation, resumeFrom ->
            orchestrator.run(bundle, messages, cancellation, resumeFrom)
        }
    }

    private fun createAgent(taskId: String, profile: AgentProfile): AgentCore {
        val workspaceValue = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.WORKSPACE_URI, null)
            ?: error("尚未选择项目目录")
        val workspace = Uri.parse(workspaceValue)
        val modelClient = OpenAiModelGateway(AndroidKeyStoreModelConfig(this))
        currentModelClient = modelClient
        val mode = if (profile.mode == AgentProfileMode.ACT) AgentMode.ACT else AgentMode.PLAN
        val model = OpenAiAgentModelGateway(modelClient, mode, profile.toolNames)
        val shellDir = File(filesDir, "shell-workdir").also { it.mkdirs() }
        val shell = ShellToolExecutor(shellDir)
        val sessions = ShellSessionManager(shellDir)
        shellSessions = sessions
        val mcp = McpToolBridge(McpConfigProvider.fromWorkspace(SafWorkspaceFileExecutor(applicationContext, workspace)))
        val tools = SafWorkspaceToolExecutor(
            SafWorkspaceFileExecutor(applicationContext, workspace),
            shell,
            WorkspaceBackupStore(this),
            sessions,
            mcp,
            profile.allowedCapabilities,
            profile.toolNames,
        )
        val eventStore = SessionEventStore(this, taskId)
        val baseApprovalPolicy = tools.approvalPolicy()
        val approvalPolicy = ToolApprovalPolicy { call ->
            if (ApprovalBridge.gateway.isAutoApproved(call.name)) {
                false
            } else if (call.name == "run_command") {
                val command = runCatching {
                    org.json.JSONObject(call.argumentsJson.ifBlank { "{}" }).optString("command")
                }.getOrDefault("")
                !ShellToolExecutor.isSafeCommand(command)
            } else {
                baseApprovalPolicy.requiresApproval(call)
            }
        }
        return AgentCore(
            model = model,
            tools = tools,
            approvals = ApprovalBridge.gateway,
            checkpoints = checkpointStore(taskId),
            limits = profile.limits,
            approvalPolicy = approvalPolicy,
            observer = AgentObserver { event ->
                if (event !is AgentEvent.ModelDelta) {
                    runCatching { eventStore.append(event.toSessionEvent()) }
                }
                when (event) {
                    is AgentEvent.ModelDelta -> {
                        broadcastModelDelta(event.text)
                    }
                    is AgentEvent.ModelStarted -> broadcastStatus(TaskState.RUNNING.name, "正在请求模型（第 ${event.round} 轮）")
                    is AgentEvent.ModelFinished -> broadcastStatus(
                        TaskState.RUNNING.name,
                        "模型响应完成，正在准备下一步",
                        contextTokens = event.inputTokens + event.outputTokens,
                    )
                    is AgentEvent.ApprovalWaiting -> broadcastStatus(
                        STATE_AWAITING_APPROVAL,
                        "等待审批：${event.call.name}",
                        event.call.name,
                        event.call.id,
                        "WAITING_FOR_APPROVAL",
                        event.call.argumentsJson,
                    )
                    is AgentEvent.ApprovalFinished -> broadcastStatus(
                        TaskState.RUNNING.name,
                        "审批结果：${event.decision}",
                        event.call.name,
                        event.call.id,
                        when (event.decision) {
                            null -> "FAILED"
                            ApprovalDecision.REJECT -> "CANCELLED"
                            ApprovalDecision.APPROVE -> ""
                        },
                    )
                    is AgentEvent.ToolStarted -> broadcastStatus(
                        TaskState.RUNNING.name,
                        "正在执行：${event.toolName}",
                        event.toolName,
                        event.toolCallId,
                        "RUNNING",
                        event.argumentsJson,
                        toolStartedAtMillis = System.currentTimeMillis(),
                    )
                    is AgentEvent.ToolFinished -> broadcastStatus(
                        TaskState.RUNNING.name,
                        "${event.toolName} 完成（${event.durationMillis}ms）",
                        event.toolName,
                        event.toolCallId,
                        if (event.succeeded) "FINISHED" else "FAILED",
                        event.result,
                        toolDurationMillis = event.durationMillis,
                    )
                }
            },
        )
    }

    private fun checkpointStore(taskId: String): CheckpointStore {
        val legacyCheckpoints = AgentCheckpointStore(this)
        val eventStore = SessionEventStore(this, taskId)
        return CheckpointStore { checkpoint ->
            legacyCheckpoints.save(checkpoint)
            eventStore.append(SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint))
        }
    }

    private fun requireSelection(id: String) {
        if (id.startsWith(BUNDLE_PREFIX)) profiles.requireBundle(id.removePrefix(BUNDLE_PREFIX))
        else profiles.requireProfile(id)
    }

    private fun buildInitialMessages(profile: AgentProfile, prompt: String): List<AgentMessage> = buildList {
        add(AgentMessage(MessageRole.SYSTEM, profile.systemPrompt))
        add(AgentMessage(MessageRole.USER, prompt))
    }

    private fun broadcastQueueState() {
        val pending = queue.pendingCount()
        val active = queue.activeCount()
        sendBroadcast(Intent(ACTION_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_STATE, STATE_QUEUE_UPDATED)
            putExtra(EXTRA_DETAIL, "运行和等待共 $active 项，其中 $pending 项等待")
            putExtra(EXTRA_QUEUE_COUNT, active)
            putExtra(EXTRA_ACTIVE_TASK_ID, currentTaskId.orEmpty())
        })
    }

    private fun migrateLegacyCheckpoint(eventStore: SessionEventStore): AgentCheckpoint? =
        AgentCheckpointStore(this).load()?.also { checkpoint ->
            eventStore.append(
                SessionEvent(SessionEventType.MIGRATED_CHECKPOINT, checkpoint = checkpoint),
            )
        }

    private fun sourcePrompt(sourceId: String?): String = FileSessionStore(this).list()
        .firstOrNull { it.id == sourceId }
        ?.prompt
        ?.takeIf { it.isNotBlank() }
        ?: "会话分支"

    private fun AgentEvent.toSessionEvent(): SessionEvent = when (this) {
        is AgentEvent.ModelDelta -> SessionEvent(SessionEventType.MODEL_DELTA, "characters=${text.length}")
        is AgentEvent.ModelStarted -> SessionEvent(SessionEventType.MODEL_STARTED, "round=$round")
        is AgentEvent.ModelFinished -> SessionEvent(
            SessionEventType.MODEL_FINISHED,
            "round=$round,durationMillis=$durationMillis,succeeded=$succeeded," +
                "inputTokens=$inputTokens,outputTokens=$outputTokens",
        )
        is AgentEvent.ApprovalWaiting -> SessionEvent(
            SessionEventType.APPROVAL_WAITING,
            "toolCallId=${call.id},tool=${call.name}",
        )
        is AgentEvent.ApprovalFinished -> SessionEvent(
            SessionEventType.APPROVAL_FINISHED,
            "toolCallId=${call.id},durationMillis=$durationMillis,decision=${decision?.name.orEmpty()}",
        )
        is AgentEvent.ToolStarted -> SessionEvent(
            SessionEventType.TOOL_STARTED,
            "toolCallId=$toolCallId,tool=$toolName",
        )
        is AgentEvent.ToolFinished -> SessionEvent(
            SessionEventType.TOOL_FINISHED,
            "toolCallId=$toolCallId,tool=$toolName,durationMillis=$durationMillis,succeeded=$succeeded",
        )
    }

    private fun broadcastStatus(state: String, detail: String) {
        broadcastStatus(state, detail, null, null, null)
    }

    private fun broadcastStatus(
        state: String,
        detail: String,
        toolName: String? = null,
        toolCallId: String? = null,
        toolState: String? = null,
        toolArgs: String? = null,
        toolResult: String? = null,
        toolDurationMillis: Long? = null,
        toolStartedAtMillis: Long? = null,
        contextTokens: Int = -1,
    ) {
        sendBroadcast(Intent(ACTION_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_STATE, state)
            putExtra(EXTRA_DETAIL, detail)
            putExtra(EXTRA_TOOL_NAME, toolName.orEmpty())
            putExtra(EXTRA_TOOL_CALL_ID, toolCallId.orEmpty())
            putExtra(EXTRA_TOOL_STATE, toolState.orEmpty())
            putExtra(EXTRA_TOOL_ARGS, toolArgs.orEmpty())
            putExtra(EXTRA_TOOL_RESULT, toolResult.orEmpty())
            putExtra(EXTRA_TOOL_DURATION_MILLIS, toolDurationMillis ?: -1L)
            putExtra(EXTRA_TOOL_STARTED_AT_MILLIS, toolStartedAtMillis ?: -1L)
            putExtra(EXTRA_CONTEXT_TOKENS, contextTokens)
        })
    }

    private fun broadcastModelDelta(text: String) {
        sendBroadcast(Intent(ACTION_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_STATE, STATE_MODEL_DELTA)
            putExtra(EXTRA_DETAIL, text)
            putExtra(EXTRA_CONTEXT_TOKENS, -1)
        })
    }

    private fun showNotification(title: String, text: String, approvalPending: Boolean = false) {
        val target = if (approvalPending) ApprovalActivity::class.java else MainActivity::class.java
        val open = PendingIntent.getActivity(
            this,
            if (approvalPending) 1 else 0,
            Intent(this, target),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (currentTaskId != null) {
            startForeground(NOTIFICATION_ID, notification)
        } else {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }
    }

    private fun stateDescription(state: TaskState): String = when (state) {
        TaskState.STARTING -> "任务启动中"
        TaskState.RUNNING -> "任务执行中"
        TaskState.STOPPING -> "任务停止中"
        TaskState.CANCELLING -> "任务取消中"
        TaskState.COMPLETED -> "任务已完成"
        TaskState.STOPPED -> "任务已停止"
        TaskState.FAILED -> "任务执行失败"
    }

    companion object {
        const val CHANNEL = "luma_tasks"
        const val ACTION_START = "dev.shelly.hermes.action.START_TASK"
        const val ACTION_RESUME = "dev.shelly.hermes.action.RESUME_TASK"
        const val ACTION_FORK_TASK = "dev.shelly.hermes.action.FORK_TASK"
        const val ACTION_STOP = "dev.shelly.hermes.action.STOP_TASK"
        const val ACTION_CANCEL_QUEUED = "dev.shelly.hermes.action.CANCEL_QUEUED_TASK"
        const val ACTION_RETRY_QUEUED = "dev.shelly.hermes.action.RETRY_QUEUED_TASK"
        const val ACTION_STATUS = "dev.shelly.hermes.action.TASK_STATUS"
        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_PROMPT = "prompt"
        const val EXTRA_MODE = "mode"
        const val EXTRA_PROFILE_ID = "profile_id"
        const val EXTRA_SOURCE_SESSION_ID = "source_session_id"
        const val EXTRA_SOURCE_SEQUENCE = "source_sequence"
        const val EXTRA_STATE = "state"
        const val EXTRA_DETAIL = "detail"
        const val EXTRA_QUEUE_COUNT = "queue_count"
        const val EXTRA_ACTIVE_TASK_ID = "active_task_id"
        const val EXTRA_TOOL_NAME = "tool_name"
        const val EXTRA_TOOL_CALL_ID = "tool_call_id"
        const val EXTRA_TOOL_STATE = "tool_state"
        const val EXTRA_TOOL_ARGS = "tool_args"
        const val EXTRA_TOOL_RESULT = "tool_result"
        const val EXTRA_TOOL_DURATION_MILLIS = "extra_tool_duration_millis"
        const val EXTRA_TOOL_STARTED_AT_MILLIS = "extra_tool_started_at_millis"
        const val EXTRA_CONTEXT_TOKENS = "context_tokens"
        const val STATE_AWAITING_APPROVAL = "AWAITING_APPROVAL"
        const val STATE_MODEL_DELTA = "MODEL_DELTA"
        const val STATE_QUEUED = "QUEUED"
        const val STATE_QUEUE_UPDATED = "QUEUE_UPDATED"
        private const val NOTIFICATION_ID = 7
        const val BUNDLE_PREFIX = "bundle:"
        private val TERMINAL_TASK_STATES = setOf(TaskState.COMPLETED, TaskState.STOPPED, TaskState.FAILED)
    }
}
