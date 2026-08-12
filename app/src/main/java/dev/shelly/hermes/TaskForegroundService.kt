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
import dev.shelly.hermes.core.ToolApprovalPolicy
import dev.shelly.hermes.core.MessageRole

/** Runs one user-started agent task in a foreground service. */
class TaskForegroundService : Service(), ForegroundServiceConnection, TaskStateListener {
    private lateinit var coordinator: AgentCoreAndroidCoordinator
    private var currentTaskId: String? = null
    @Volatile private var currentModelClient: OpenAiModelGateway? = null

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(CHANNEL, "Luma 任务", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        coordinator = AgentCoreAndroidCoordinator(
            agentFactory = { createAgent() },
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
            ACTION_START -> Unit
            else -> return START_NOT_STICKY
        }

        val taskId = intent.getStringExtra(EXTRA_TASK_ID)?.takeIf { it.isNotBlank() }
        val prompt = intent.getStringExtra(EXTRA_PROMPT)?.trim().orEmpty()
        if (taskId == null || prompt.isBlank()) {
            broadcastStatus(TaskState.FAILED.name, "任务参数不完整")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (currentTaskId != null) {
            broadcastStatus(TaskState.FAILED.name, "已有任务正在执行，请先停止当前任务")
            return START_NOT_STICKY
        }

        currentTaskId = taskId
        FileSessionStore(this).save(Session(taskId, prompt.take(120), System.currentTimeMillis()))
        if (!coordinator.start(taskId, listOf(AgentMessage(MessageRole.USER, prompt)))) {
            currentTaskId = null
            broadcastStatus(TaskState.FAILED.name, "任务未能启动")
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        currentModelClient?.cancelCurrentRequest()
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
        currentTaskId = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
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
        broadcastStatus(status.state.name, detail)
    }

    private fun createAgent(): AgentCore {
        val workspaceValue = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.WORKSPACE_URI, null)
            ?: error("尚未选择项目目录")
        val workspace = Uri.parse(workspaceValue)
        val modelClient = OpenAiModelGateway(AndroidKeyStoreModelConfig(this))
        currentModelClient = modelClient
        val model = OpenAiAgentModelGateway(modelClient)
        val tools = SafWorkspaceToolExecutor(SafWorkspaceFileExecutor(applicationContext, workspace))
        return AgentCore(
            model = model,
            tools = tools,
            approvals = ApprovalBridge.gateway,
            checkpoints = AgentCheckpointStore(this),
            approvalPolicy = ToolApprovalPolicy.autoApproveReadOnly(),
            observer = AgentObserver { event ->
                when (event) {
                    is AgentEvent.ModelStarted -> broadcastStatus(TaskState.RUNNING.name, "正在请求模型（第 ${event.round} 轮）")
                    is AgentEvent.ModelFinished -> broadcastStatus(TaskState.RUNNING.name, "模型响应耗时 ${event.durationMillis}ms")
                    is AgentEvent.ApprovalWaiting -> broadcastStatus(STATE_AWAITING_APPROVAL, "等待审批：${event.call.name}")
                    is AgentEvent.ApprovalFinished -> broadcastStatus(TaskState.RUNNING.name, "审批结果：${event.decision}")
                    is AgentEvent.ToolStarted -> broadcastStatus(TaskState.RUNNING.name, "正在执行：${event.toolName}")
                    is AgentEvent.ToolFinished -> broadcastStatus(TaskState.RUNNING.name, "${event.toolName} 完成（${event.durationMillis}ms）")
                }
            },
        )
    }

    private fun broadcastStatus(state: String, detail: String) {
        sendBroadcast(Intent(ACTION_STATUS).apply {
            setPackage(packageName)
            putExtra(EXTRA_STATE, state)
            putExtra(EXTRA_DETAIL, detail)
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
        const val ACTION_STOP = "dev.shelly.hermes.action.STOP_TASK"
        const val ACTION_STATUS = "dev.shelly.hermes.action.TASK_STATUS"
        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_PROMPT = "prompt"
        const val EXTRA_STATE = "state"
        const val EXTRA_DETAIL = "detail"
        const val STATE_AWAITING_APPROVAL = "AWAITING_APPROVAL"
        private const val NOTIFICATION_ID = 7
    }
}
