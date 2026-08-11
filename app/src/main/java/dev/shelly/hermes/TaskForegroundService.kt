package dev.shelly.hermes

import android.app.*
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import dev.shelly.hermes.core.AgentCore
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.CheckpointStore
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.ModelGateway
import dev.shelly.hermes.core.ModelReply
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolExecutor

/**
 * Hosts [AgentCoreAndroidCoordinator] in the foreground service and wires the real
 * [AndroidApprovalGateway] into the agent so intrusive tool calls pause for human approval.
 */
class TaskForegroundService : Service(), ForegroundServiceConnection, TaskStateListener {

    private lateinit var coordinator: AgentCoreAndroidCoordinator
    private var currentTaskId: String? = null

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(CHANNEL, "任务执行", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)

        val checkpoints: CheckpointStore = AgentCheckpointStore(this)
        val approvals = ApprovalBridge.gateway

        coordinator = AgentCoreAndroidCoordinator(
            agentFactory = { taskId ->
                var modelCalls = 0
                AgentCore(
                    model = ModelGateway { _ ->
                        // Demo model: request one approval-gated edit_file call, then complete.
                        if (++modelCalls == 1) {
                            ModelReply(
                                content = "",
                                toolCalls = listOf(ToolCall("$taskId-1", "edit_file", """{"path":"demo.md","content":"+line"}""")),
                                inputTokens = 10,
                                outputTokens = 10
                            )
                        } else {
                            ModelReply(content = "已完成演示任务", inputTokens = 5, outputTokens = 5)
                        }
                    },
                    tools = ToolExecutor { "模拟执行成功" },
                    approvals = approvals,
                    checkpoints = checkpoints,
                    limits = dev.shelly.hermes.core.AgentLimits(maxRounds = 2)
                )
            },
            foregroundService = this,
            listener = this
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(
            7,
            NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Shelly Hermes 正在执行任务")
                .setContentText("可返回应用查看进度或审批")
                .setOngoing(true)
                .setContentIntent(open)
                .build()
        )
        val taskId = "task-${System.currentTimeMillis()}"
        currentTaskId = taskId
        FileSessionStore(this).save(Session("active", "前台任务", System.currentTimeMillis()))
        coordinator.start(taskId, listOf(AgentMessage(MessageRole.USER, "修改 demo.md")))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun start(taskId: String) = update(taskId, TaskState.STARTING)
    override fun update(taskId: String, state: TaskState) {
        // Keep the notification in sync with the current task state.
        getSystemService(NotificationManager::class.java).notify(
            7,
            NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Shelly Hermes")
                .setContentText(stateDescription(state))
                .setOngoing(true)
                .build()
        )
    }
    override fun stop(taskId: String) { stopForeground(STOP_FOREGROUND_REMOVE) }

    override fun onStateChanged(status: TaskStatus) {
        FileSessionStore(this).save(Session("active", "任务状态：${status.state}", System.currentTimeMillis()))
    }

    private fun stateDescription(state: TaskState): String = when (state) {
        TaskState.STARTING -> "任务启动中"
        TaskState.RUNNING -> "任务执行中"
        TaskState.STOPPING -> "任务停止中"
        TaskState.CANCELLING -> "任务取消中"
        TaskState.COMPLETED -> "任务已完成"
        TaskState.STOPPED -> "任务已停止"
        TaskState.FAILED -> "任务失败"
    }

    companion object { const val CHANNEL = "hermes_tasks" }
}