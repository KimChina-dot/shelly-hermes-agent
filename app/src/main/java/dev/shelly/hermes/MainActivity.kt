package dev.shelly.hermes

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Network
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.KeyEvent
import android.view.inputmethod.InputMethodManager
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.bottomnavigation.BottomNavigationView
import dev.shelly.hermes.core.AgentProfileMode
import dev.shelly.hermes.core.AgentProfileRegistry
import androidx.recyclerview.widget.DefaultItemAnimator
import org.json.JSONObject

data class AttachmentRef(val name: String, val preview: String)

class MainActivity : AppCompatActivity() {
    private lateinit var messages: MutableList<UiMessage>
    private lateinit var messageAdapter: AgentMessageAdapter
    private val profiles = AgentProfileRegistry()
    private var lastPrompt: String = ""
    private var currentMode: AgentMode = AgentMode.ACT
    private var currentProfileId: String = "coding"
    private val streamHandler = Handler(Looper.getMainLooper())
    private val streamBuffer = StringBuilder()
    private var streamingMessage: UiMessage? = null
    private var streamFlushScheduled = false

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@registerForActivityResult
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            showSetupIssue("无法保留目录权限，请重新选择项目目录。", "重新选择项目") {
                picker.launch(null)
            }
            return@registerForActivityResult
        }
        getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE)
            .edit()
            .putString(WORKSPACE_URI, uri.toString())
            .apply()
        hideSetupIssue()
        refreshConfigurationStatus()
    }

    private val documentPicker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@registerForActivityResult
        addAttachment(uri)
    }

    private val attachments = mutableListOf<AttachmentRef>()
    private val artifactMessages = mutableListOf<UiMessage>()
    private var contextTokensFromModel = 0
    private var timelineModelState = "PENDING"
    private var timelineToolState = "PENDING"
    private var timelineApprovalState = "PENDING"
    private var timelineToolName = ""
    private var isTaskRunning = false
    private var setupActionHandler: (() -> Unit)? = null

    private val taskStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != TaskForegroundService.ACTION_STATUS) return
            val state = intent.getStringExtra(TaskForegroundService.EXTRA_STATE).orEmpty()
            val detail = intent.getStringExtra(TaskForegroundService.EXTRA_DETAIL).orEmpty()
            val activeTaskId = intent.getStringExtra(TaskForegroundService.EXTRA_ACTIVE_TASK_ID).orEmpty()
            val queueCount = intent.getIntExtra(TaskForegroundService.EXTRA_QUEUE_COUNT, -1)
            val toolName = intent.getStringExtra(TaskForegroundService.EXTRA_TOOL_NAME).orEmpty()
            val toolCallId = intent.getStringExtra(TaskForegroundService.EXTRA_TOOL_CALL_ID).orEmpty()
            val toolState = intent.getStringExtra(TaskForegroundService.EXTRA_TOOL_STATE).orEmpty()
            val toolArgs = intent.getStringExtra(TaskForegroundService.EXTRA_TOOL_ARGS).orEmpty()
            val toolResult = intent.getStringExtra(TaskForegroundService.EXTRA_TOOL_RESULT).orEmpty()
            val toolDurationMillis = intent.getLongExtra(TaskForegroundService.EXTRA_TOOL_DURATION_MILLIS, -1L)
            val toolStartedAtMillis = intent.getLongExtra(TaskForegroundService.EXTRA_TOOL_STARTED_AT_MILLIS, -1L)
            val contextTokens = intent.getIntExtra(TaskForegroundService.EXTRA_CONTEXT_TOKENS, -1)
            if (contextTokens > 0) contextTokensFromModel = contextTokens
            renderTaskState(
                state,
                detail,
                activeTaskId,
                queueCount,
                toolName,
                toolCallId,
                toolState,
                toolArgs,
                toolResult,
                if (toolDurationMillis >= 0) toolDurationMillis else null,
                if (toolStartedAtMillis >= 0) toolStartedAtMillis else null,
            )
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            runOnUiThread { updateOfflineBanner(online = isOnline()) }
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            runOnUiThread { updateOfflineBanner(online = isOnline()) }
        }

        override fun onLost(network: Network) {
            runOnUiThread { updateOfflineBanner(online = isOnline()) }
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_main)

        messages = mutableListOf()
        messageAdapter = AgentMessageAdapter(
            this,
            messages,
            onRetry = { retryLastTask() },
            onRegenerate = { regenerateLastReply() },
            onOpenArtifact = { openArtifact(it) },
            onShareArtifact = { shareArtifact(it) },
            onDownloadArtifact = { downloadArtifact(it) },
        )
        findViewById<RecyclerView>(R.id.messageList).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = messageAdapter
            itemAnimator = DefaultItemAnimator().apply {
                addDuration = resources.getInteger(R.integer.animation_duration_medium).toLong()
                changeDuration = resources.getInteger(R.integer.animation_duration_medium).toLong()
                moveDuration = resources.getInteger(R.integer.animation_duration_medium).toLong()
                removeDuration = resources.getInteger(R.integer.animation_duration_medium).toLong()
            }
        }

        findViewById<Button>(R.id.chooseWorkspace).setOnClickListener { picker.launch(null) }
        findViewById<Button>(R.id.taskQueue).setOnClickListener {
            startActivity(Intent(this, TaskQueueActivity::class.java))
        }
        findViewById<Button>(R.id.settings).setOnClickListener { showModelSettingsDialog() }
        findViewById<Button>(R.id.taskMode).setOnClickListener {
            selectProfile(if (currentMode == AgentMode.ACT) "planner" else "coding")
        }
        findViewById<Button>(R.id.agentProfile).setOnClickListener {
            showProfileSelector()
        }
        findViewById<Button>(R.id.startTask).setOnClickListener { startTask() }
        findViewById<EditText>(R.id.taskInput).setOnEditorActionListener { _, actionId, event ->
            val isSendAction = actionId == EditorInfo.IME_ACTION_SEND
            val isEnter = event?.keyCode == KeyEvent.KEYCODE_ENTER &&
                event.action == KeyEvent.ACTION_DOWN
            if (isSendAction || isEnter) {
                startTask()
                true
            } else {
                false
            }
        }
        findViewById<Button>(R.id.attachButton).setOnClickListener {
            documentPicker.launch(
                arrayOf(
                    "text/*",
                    "application/json",
                    "application/xml",
                    "application/javascript",
                    "application/typescript",
                ),
            )
        }
        findViewById<Button>(R.id.resumeTask).setOnClickListener { resumeTask() }
        findViewById<Button>(R.id.stopTask).setOnClickListener { stopTask() }
        findViewById<Button>(R.id.retry).setOnClickListener {
            if (lastPrompt.isNotBlank()) {
                findViewById<EditText>(R.id.taskInput).setText(lastPrompt)
                startTask()
            }
        }
        findViewById<Button>(R.id.resumeStoppedTask).setOnClickListener { resumeTask() }
        findViewById<Button>(R.id.startNewTask).setOnClickListener {
            findViewById<View>(R.id.errorContainer).visibility = View.GONE
            findViewById<View>(R.id.stoppedContainer).visibility = View.GONE
            hideSetupIssue()
            contextTokensFromModel = 0
            val input = findViewById<EditText>(R.id.taskInput)
            input.text.clear()
            input.requestFocus()
            getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                ?.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
            updateContextIndicator()
        }
        findViewById<Button>(R.id.approval).setOnClickListener {
            startActivity(Intent(this, ApprovalActivity::class.java))
        }
        findViewById<BottomNavigationView>(R.id.bottomNav).apply {
            selectedItemId = R.id.nav_chat
            setOnItemSelectedListener { item ->
                when (item.itemId) {
                    R.id.nav_tasks -> {
                        startActivity(Intent(this@MainActivity, TaskQueueActivity::class.java))
                        true
                    }
                    R.id.nav_history -> {
                        startActivity(Intent(this@MainActivity, HistoryActivity::class.java))
                        true
                    }
                    R.id.nav_capabilities -> {
                        startActivity(Intent(this@MainActivity, CapabilitiesActivity::class.java))
                        true
                    }
                    else -> true
                }
            }
        }

        ApprovalBridge.gateway.launcher = {
            runOnUiThread { startActivity(Intent(this, ApprovalActivity::class.java)) }
        }
        currentProfileId = getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(AGENT_PROFILE_ID, "coding")
            ?.takeIf { profiles.findProfile(it) != null || it == TEAM_PROFILE_ID }
            ?: "coding"
        renderProfile()
        refreshConfigurationStatus()
    }

    override fun onStart() {
        super.onStart()
        ContextCompat.registerReceiver(
            this,
            taskStatusReceiver,
            IntentFilter(TaskForegroundService.ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        runCatching {
            getSystemService(ConnectivityManager::class.java)
                ?.registerDefaultNetworkCallback(networkCallback)
        }
        updateOfflineBanner(isOnline())
    }

    override fun onStop() {
        unregisterReceiver(taskStatusReceiver)
        runCatching {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(networkCallback)
        }
        super.onStop()
    }

    override fun onDestroy() {
        streamHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        refreshConfigurationStatus()
        runCatching { AgentTaskQueueStore(this).activeCount() }.onSuccess { count ->
            findViewById<Button>(R.id.taskQueue).text = "任务 $count"
        }
    }

    private fun startTask() {
        if (isTaskRunning) return
        contextTokensFromModel = 0
        val input = findViewById<EditText>(R.id.taskInput)
        val prompt = input.text.toString().trim()
        if (prompt.isBlank()) {
            input.error = "请输入任务内容"
            return
        }
        val effectivePrompt = buildString {
            append(prompt)
            if (attachments.isNotEmpty()) {
                append("\n\n附件上下文：\n")
                attachments.forEach { item ->
                    append("- ")
                    append(item.name)
                    append("：")
                    append(item.preview.take(400))
                    append("\n")
                }
            }
        }
        if (workspaceUri() == null) {
            showSetupIssue("请先选择项目目录，才能读取和修改工作区。", "选择项目") {
                picker.launch(null)
            }
            return
        }
        if (AndroidKeyStoreModelConfig(this).load() == null) {
            showSetupIssue("请先完成模型设置，再发送 Agent 任务。", "设置模型") {
                showModelSettingsDialog()
            }
            return
        }
        if (!isOnline()) {
            updateOfflineBanner(online = false)
            return
        }

        lastPrompt = prompt
        flushStreaming()
        streamingMessage = null
        appendMessage(UiMessageRole.USER, prompt)
        input.text.clear()
        findViewById<View>(R.id.errorContainer).visibility = View.GONE
        findViewById<View>(R.id.stoppedContainer).visibility = View.GONE
        hideSetupIssue()

        val intent = Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_START
            putExtra(TaskForegroundService.EXTRA_TASK_ID, "task-${System.currentTimeMillis()}")
            putExtra(TaskForegroundService.EXTRA_PROMPT, effectivePrompt)
            putExtra(TaskForegroundService.EXTRA_MODE, currentMode.wireValue)
            putExtra(TaskForegroundService.EXTRA_PROFILE_ID, currentProfileId)
        }
        attachments.clear()
        renderAttachmentTray()
        ContextCompat.startForegroundService(this, intent)
    }

    private fun retryLastTask() {
        if (lastPrompt.isBlank() || isTaskRunning) return
        appendMessage(UiMessageRole.STATUS, "正在重试上次任务")
        findViewById<EditText>(R.id.taskInput).setText(lastPrompt)
        startTask()
    }

    private fun regenerateLastReply() {
        if (lastPrompt.isBlank() || isTaskRunning) return
        appendMessage(UiMessageRole.STATUS, "正在重新生成回复")
        findViewById<EditText>(R.id.taskInput).setText(lastPrompt)
        startTask()
    }

    private fun stopTask() {
        startService(Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_STOP
        })
    }

    private fun resumeTask() {
        val durableSession = latestResumableSession()
        if (durableSession == null && !AgentCheckpointStore(this).hasCheckpoint()) {
            Toast.makeText(this, "No task checkpoint is available", Toast.LENGTH_SHORT).show()
            return
        }
        ContextCompat.startForegroundService(this, Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_RESUME
            putExtra(
                TaskForegroundService.EXTRA_TASK_ID,
                durableSession?.id ?: "resume-${System.currentTimeMillis()}",
            )
            putExtra(TaskForegroundService.EXTRA_MODE, currentMode.wireValue)
            putExtra(TaskForegroundService.EXTRA_PROFILE_ID, currentProfileId)
        })
    }

    private fun latestResumableSession() = FileSessionStore(this).list().firstOrNull { session ->
        runCatching { SessionEventStore(this, session.id).hasCheckpoint() }.getOrDefault(false)
    }

    private fun renderTaskState(
        state: String,
        detail: String,
        activeTaskId: String,
        queueCount: Int,
        toolName: String = "",
        toolCallId: String = "",
        toolState: String = "",
        toolArgs: String = "",
        toolResult: String = "",
        toolDurationMillis: Long? = null,
        toolStartedAtMillis: Long? = null,
    ) {
        if (queueCount >= 0) findViewById<Button>(R.id.taskQueue).text = "任务 $queueCount"
        updateStoppedRecovery(state, activeTaskId)
        updateTaskStatus(state, detail, activeTaskId, queueCount, toolState)
        updateTaskTimeline(state, detail, toolState, activeTaskId, toolName)
        when (state) {
            TaskState.STARTING.name -> setRunning(true)
            TaskForegroundService.STATE_MODEL_DELTA -> appendStreamDelta(detail)
            TaskForegroundService.STATE_QUEUED -> appendMessage(UiMessageRole.STATUS, "任务已加入执行队列")
            TaskForegroundService.STATE_QUEUE_UPDATED -> setRunning(activeTaskId.isNotBlank())
            TaskForegroundService.STATE_AWAITING_APPROVAL -> {
                flushStreaming()
                setRunning(true)
                findViewById<Button>(R.id.approval).visibility = View.VISIBLE
                if (toolName.isNotBlank() && toolCallId.isNotBlank()) {
                    appendToolMessage(
                        toolName,
                        toolCallId,
                        detail,
                        "WAITING_FOR_APPROVAL",
                        toolArgs,
                    )
                }
                startActivity(Intent(this, ApprovalActivity::class.java))
            }
            TaskState.RUNNING.name -> {
                setRunning(true)
                when (toolState) {
                    "RUNNING" -> appendToolMessage(
                        toolName,
                        toolCallId,
                        detail,
                        toolState,
                        toolArgs,
                        toolStartedAtMillis,
                    )
                    "FINISHED", "FAILED" -> updateToolMessage(
                        toolCallId,
                        detail,
                        toolState,
                        toolResult,
                        toolName,
                        toolDurationMillis,
                    )
                    "CANCELLED" -> updateToolMessage(
                        toolCallId,
                        detail,
                        "CANCELLED",
                        toolResult,
                        toolName,
                    )
                    else -> if (detail.startsWith("正在请求模型")) {
                        flushStreaming()
                        streamingMessage = null
                    }
                }
            }
            TaskState.COMPLETED.name -> {
                setRunning(false)
                findViewById<Button>(R.id.approval).visibility = View.GONE
                val completion = detail.ifBlank { "任务已完成" }
                flushStreaming()
                if (streamingMessage?.text != completion) {
                    appendMessage(UiMessageRole.ASSISTANT, completion)
                }
                streamingMessage = null
            }
            TaskState.STOPPED.name, TaskState.CANCELLING.name, TaskState.STOPPING.name -> {
                setRunning(state == TaskState.CANCELLING.name || state == TaskState.STOPPING.name)
                if (state == TaskState.STOPPED.name) appendMessage(UiMessageRole.STATUS, "任务已停止")
            }
            TaskState.FAILED.name -> {
                flushStreaming()
                streamingMessage = null
                setRunning(false)
                val normalized = detail.lowercase()
                val contextOverLimit = "context" in normalized || "token" in normalized
                findViewById<TextView>(R.id.errorText).text = if (contextOverLimit) {
                    "上下文过长：请减少附件或用更短的任务描述重新开始。模型返回：${detail.ifBlank { "请求超出可用上下文" }}"
                } else {
                    detail.ifBlank { "任务执行失败" }
                }
                findViewById<View>(R.id.errorContainer).visibility = View.VISIBLE
                findViewById<Button>(R.id.retry).visibility = if (contextOverLimit) View.GONE else View.VISIBLE
                findViewById<Button>(R.id.startNewTask).visibility = if (contextOverLimit) View.VISIBLE else View.GONE
                findViewById<Button>(R.id.retry).contentDescription = "重试上次任务"
                findViewById<Button>(R.id.startNewTask).contentDescription = "放弃当前上下文并输入新任务"
            }
        }
    }

    private fun updateStoppedRecovery(state: String, activeTaskId: String) {
        val container = findViewById<View>(R.id.stoppedContainer)
        if (state == TaskState.STOPPING.name || state == TaskState.CANCELLING.name) {
            container.visibility = View.GONE
            return
        }
        val shouldShow = state == TaskState.STOPPED.name ||
            (state == TaskForegroundService.STATE_QUEUE_UPDATED && activeTaskId.isBlank() &&
                container.visibility == View.VISIBLE)
        if (!shouldShow) {
            container.visibility = View.GONE
            return
        }
        val canResume = latestResumableSession() != null || AgentCheckpointStore(this).hasCheckpoint()
        findViewById<TextView>(R.id.stoppedText).text = if (canResume) {
            "任务已停止。已保留检查点，可以从当前进度继续。"
        } else {
            "任务已停止。没有可用检查点，请输入新任务或重试。"
        }
        val resumeButton = findViewById<Button>(R.id.resumeStoppedTask)
        resumeButton.visibility = if (canResume) View.VISIBLE else View.GONE
        resumeButton.contentDescription = "继续已停止的任务"
        container.visibility = View.VISIBLE
    }

    private fun showSetupIssue(
        message: String,
        actionText: String? = null,
        action: (() -> Unit)? = null,
    ) {
        setupActionHandler = action
        findViewById<TextView>(R.id.setupText).text = message
        val actionButton = findViewById<Button>(R.id.setupAction)
        if (actionText != null && action != null) {
            actionButton.text = actionText
            actionButton.contentDescription = "$actionText：解决当前设置问题"
            actionButton.setOnClickListener { setupActionHandler?.invoke() }
            actionButton.visibility = View.VISIBLE
        } else {
            actionButton.setOnClickListener(null)
            actionButton.visibility = View.GONE
        }
        findViewById<View>(R.id.setupContainer).visibility = View.VISIBLE
    }

    private fun hideSetupIssue() {
        setupActionHandler = null
        findViewById<View>(R.id.setupContainer).visibility = View.GONE
        findViewById<Button>(R.id.setupAction).setOnClickListener(null)
    }

    private fun stateDescription(state: String): String = when (state) {
        TaskState.STARTING.name -> "任务启动中"
        TaskState.RUNNING.name -> "任务执行中"
        TaskForegroundService.STATE_MODEL_DELTA -> "模型正在生成"
        TaskState.STOPPING.name -> "任务停止中"
        TaskState.CANCELLING.name -> "任务取消中"
        TaskForegroundService.STATE_QUEUE_UPDATED -> "任务队列运行中"
        TaskForegroundService.STATE_AWAITING_APPROVAL -> "等待审批"
        else -> state
    }

    private fun updateTaskStatus(
        state: String,
        detail: String,
        activeTaskId: String,
        queueCount: Int,
        toolState: String,
    ) {
        val status = findViewById<TextView>(R.id.taskStatus)
        val hidden = state == TaskState.COMPLETED.name || state == TaskState.FAILED.name ||
            state == TaskState.STOPPED.name ||
            (state == TaskForegroundService.STATE_QUEUE_UPDATED && activeTaskId.isBlank() && queueCount == 0)
        status.text = when {
            state == TaskForegroundService.STATE_MODEL_DELTA -> stateDescription(state)
            state == TaskForegroundService.STATE_QUEUE_UPDATED -> stateDescription(state)
            state == TaskState.RUNNING.name && toolState == "RUNNING" -> detail.ifBlank { "正在执行工具" }
            else -> detail.ifBlank { stateDescription(state) }
        }
        status.contentDescription = "当前任务状态 ${status.text}"
        status.setTextColor(
            getColor(
                when (state) {
                    TaskForegroundService.STATE_AWAITING_APPROVAL -> R.color.status_warning
                    TaskForegroundService.STATE_MODEL_DELTA -> R.color.accent_primary
                    TaskState.RUNNING.name -> R.color.accent_primary
                    else -> R.color.text_secondary
                },
            ),
        )
        status.visibility = if (hidden) View.GONE else View.VISIBLE
    }

    private fun updateTaskTimeline(
        state: String,
        detail: String,
        toolState: String,
        activeTaskId: String,
        toolName: String,
    ) {
        val modelState: String
        val toolPhaseState: String
        val approvalState: String
        val resultState: String
        when (state) {
            TaskState.STARTING.name, TaskForegroundService.STATE_QUEUED -> {
                timelineModelState = "PENDING"
                timelineToolState = "PENDING"
                timelineApprovalState = "PENDING"
                timelineToolName = ""
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "PENDING"
            }
            TaskForegroundService.STATE_AWAITING_APPROVAL -> {
                timelineModelState = "FINISHED"
                timelineToolState = "PENDING"
                timelineApprovalState = "WAITING_FOR_APPROVAL"
                if (toolName.isNotBlank()) timelineToolName = toolName
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "PENDING"
            }
            TaskState.RUNNING.name, TaskForegroundService.STATE_MODEL_DELTA -> {
                when {
                    toolState == "RUNNING" -> {
                        timelineModelState = "FINISHED"
                        timelineToolState = "RUNNING"
                        if (toolName.isNotBlank()) timelineToolName = toolName
                    }
                    toolState == "FINISHED" || toolState == "FAILED" -> {
                        timelineModelState = "FINISHED"
                        timelineToolState = toolState
                        if (toolName.isNotBlank()) timelineToolName = toolName
                    }
                    detail.startsWith("模型响应完成") -> {
                        timelineModelState = "FINISHED"
                        timelineToolState = "PENDING"
                        timelineToolName = ""
                    }
                    else -> {
                        timelineModelState = "RUNNING"
                        timelineToolState = "PENDING"
                        timelineToolName = ""
                    }
                }
                timelineApprovalState = "PENDING"
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "RUNNING"
            }
            TaskForegroundService.STATE_QUEUE_UPDATED -> {
                if (activeTaskId.isBlank()) {
                    findViewById<LinearLayout>(R.id.taskTimeline).visibility = View.GONE
                    return
                }
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "RUNNING"
            }
            TaskState.COMPLETED.name -> {
                timelineModelState = "FINISHED"
                if (timelineToolState == "RUNNING") timelineToolState = "FINISHED"
                timelineApprovalState = "PENDING"
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "FINISHED"
            }
            TaskState.STOPPED.name -> {
                if (timelineModelState == "RUNNING") timelineModelState = "CANCELLED"
                if (timelineToolState == "RUNNING") timelineToolState = "CANCELLED"
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "CANCELLED"
            }
            TaskState.STOPPING.name, TaskState.CANCELLING.name -> {
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "RUNNING"
            }
            TaskState.FAILED.name -> {
                if (timelineModelState == "RUNNING") timelineModelState = "FAILED"
                if (timelineToolState == "RUNNING") timelineToolState = "FAILED"
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "FAILED"
            }
            else -> {
                findViewById<LinearLayout>(R.id.taskTimeline).visibility = View.GONE
                return
            }
        }
        val timeline = findViewById<LinearLayout>(R.id.taskTimeline)
        timeline.visibility = View.VISIBLE
        bindTimelineStep(R.id.timelineModel, "模型", modelState)
        bindTimelineStep(
            R.id.timelineTool,
            timelineToolName.ifBlank { "工具" },
            toolPhaseState,
        )
        bindTimelineStep(R.id.timelineApproval, "审批", approvalState)
        bindTimelineStep(R.id.timelineResult, "结果", resultState)
    }

    private fun bindTimelineStep(viewId: Int, label: String, state: String) {
        findViewById<TextView>(viewId).apply {
            text = when (state) {
                "RUNNING" -> "$label · 进行中"
                "FINISHED" -> "$label · 完成"
                "FAILED" -> "$label · 失败"
                "WAITING_FOR_APPROVAL" -> "$label · 等待"
                "CANCELLED" -> "$label · 已停止"
                else -> label
            }
            contentDescription = "任务阶段 $text"
            background = ContextCompat.getDrawable(context, timelineBackground(state))
            setTextColor(getColor(timelineTextColor(state)))
        }
    }

    private fun timelineBackground(state: String): Int = when (state) {
        "RUNNING" -> R.drawable.bg_chip_running
        "FINISHED" -> R.drawable.bg_chip_success
        "FAILED" -> R.drawable.bg_chip_error
        "WAITING_FOR_APPROVAL" -> R.drawable.bg_chip_warning
        "CANCELLED" -> R.drawable.bg_chip_warning
        else -> R.drawable.bg_chip
    }

    private fun timelineTextColor(state: String): Int = when (state) {
        "RUNNING" -> R.color.accent_primary
        "FINISHED" -> R.color.status_success
        "FAILED" -> R.color.status_error
        "WAITING_FOR_APPROVAL", "CANCELLED" -> R.color.status_warning
        else -> R.color.text_secondary
    }

    private fun appendMessage(role: UiMessageRole, text: String) {
        flushStreaming()
        messages += UiMessage(role, text)
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        updateContextIndicator()
        scrollToLatest()
    }

    private fun appendToolMessage(
        toolName: String,
        toolCallId: String,
        detail: String,
        state: String,
        args: String = "",
        startedAtMillis: Long? = null,
    ) {
        if (toolName.isBlank()) return
        flushStreaming()
        streamingMessage = null
        val existingIndex = toolCallId.takeIf { it.isNotBlank() }?.let { id ->
            messages.indexOfLast { message -> message.role == UiMessageRole.TOOL && message.toolCallId == id }
        } ?: -1
        if (existingIndex >= 0) {
            val existing = messages[existingIndex]
            messages[existingIndex] = existing.copy(
                text = detail,
                title = toolName,
                toolState = state,
                toolStartedAtMillis = startedAtMillis ?: existing.toolStartedAtMillis,
                toolArgs = args.ifBlank { existing.toolArgs },
            )
        } else {
            messages += UiMessage(
                role = UiMessageRole.TOOL,
                text = detail,
                title = toolName,
                toolCallId = toolCallId,
                toolState = state,
                toolStartedAtMillis = startedAtMillis,
                toolArgs = args,
            )
        }
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        updateContextIndicator()
        scrollToLatest()
    }

    private fun updateToolMessage(
        toolCallId: String,
        detail: String,
        state: String,
        result: String = "",
        toolName: String = "",
        durationMillis: Long? = null,
    ) {
        if (toolCallId.isBlank()) return
        val index = messages.indexOfLast { it.role == UiMessageRole.TOOL && it.toolCallId == toolCallId }
        if (index < 0) return
        messages[index] = messages[index].copy(
            text = detail,
            toolState = state,
            toolStartedAtMillis = messages[index].toolStartedAtMillis,
            toolDurationMillis = durationMillis,
            toolResult = result,
        )
        if (state == "FINISHED") appendArtifactIfNeeded(toolName, messages[index].toolArgs.orEmpty(), result)
        messageAdapter.notifyDataSetChanged()
        updateContextIndicator()
    }

    private fun appendArtifactIfNeeded(toolName: String, args: String, result: String) {
        if (toolName !in ARTIFACT_TOOLS) return
        val path = pathFrom(args, result) ?: return
        val content = runCatching { JSONObject(args.ifBlank { "{}" }).optString("content") }
            .getOrDefault("")
        val preview = if (content.isNotBlank()) {
            content.take(400) + if (content.length > 400) "\n…" else ""
        } else {
            result.ifBlank { "已更新文件 ${path}" }
        }
        val imageBytes = if (isImageArtifact(path)) {
            runCatching {
                workspaceUri()?.let { SafWorkspaceFileExecutor(this, it).readBytes(path, 20 * 1024 * 1024) }
            }.getOrNull()?.takeIf { it.isNotEmpty() }
        } else {
            null
        }
        flushStreaming()
        streamingMessage = null
        messages += UiMessage(
            role = UiMessageRole.ARTIFACT,
            text = preview,
            title = path.substringAfterLast('/'),
            toolCallId = null,
            toolState = "FINISHED",
            toolArgs = args,
            toolResult = result,
            artifactPath = path,
            artifactType = path.substringAfterLast('.', "file"),
            artifactImageBytes = imageBytes,
        )
        val existing = artifactMessages.indexOfFirst { it.artifactPath == path }
        if (existing >= 0) {
            artifactMessages[existing] = messages.last()
        } else {
            artifactMessages += messages.last()
        }
        renderArtifactGallery()
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        updateContextIndicator()
        scrollToLatest()
    }

    private fun isImageArtifact(path: String): Boolean =
        path.substringAfterLast('.', "").lowercase() in setOf("png", "jpg", "jpeg", "gif", "webp", "bmp")

    private fun addAttachment(uri: Uri) {
        val name = runCatching {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
        }.getOrNull() ?: uri.lastPathSegment ?: "附件"
        val preview = runCatching {
            contentResolver.openInputStream(uri)?.use { input ->
                input.bufferedReader(Charsets.UTF_8).use { it.readText().take(4000) }
            }.orEmpty()
        }.getOrDefault("")
        if (preview.isBlank()) {
            showSetupIssue("无法读取附件内容，请选择文本类文件。", "重新选择附件") {
                documentPicker.launch(
                    arrayOf(
                        "text/*",
                        "application/json",
                        "application/xml",
                        "application/javascript",
                        "application/typescript",
                    ),
                )
            }
            return
        }
        attachments += AttachmentRef(name, preview)
        renderAttachmentTray()
        updateContextIndicator()
    }

    private fun renderAttachmentTray() {
        val tray = findViewById<HorizontalScrollView>(R.id.attachmentTray)
        val list = findViewById<LinearLayout>(R.id.attachmentList)
        list.removeAllViews()
        if (attachments.isEmpty()) {
            tray.visibility = View.GONE
            return
        }
        tray.visibility = View.VISIBLE
        attachments.forEachIndexed { index, item ->
            list.addView(TextView(this).apply {
                text = "${item.name} · ${item.preview.take(400).length} 字符 · 移除"
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                setTextColor(getColor(R.color.text_primary))
                background = ContextCompat.getDrawable(context, R.drawable.bg_chip_warning)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                minHeight = dp(48)
                gravity = android.view.Gravity.CENTER_VERTICAL
                contentDescription = "附件 ${item.name}，${item.preview.take(400).length} 字符，点击移除"
                setOnClickListener {
                    attachments.removeAt(index)
                    renderAttachmentTray()
                    updateContextIndicator()
                }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = dp(8) }
            })
        }
    }

    private fun renderArtifactGallery() {
        val scroll = findViewById<HorizontalScrollView>(R.id.artifactGalleryScroll)
        val list = findViewById<LinearLayout>(R.id.artifactGalleryList)
        list.removeAllViews()
        if (artifactMessages.isEmpty()) {
            scroll.visibility = View.GONE
            return
        }
        scroll.visibility = View.VISIBLE
        artifactMessages.forEach { message ->
            list.addView(artifactGalleryCard(message))
        }
    }

    private fun artifactGalleryCard(message: UiMessage): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ContextCompat.getDrawable(context, R.drawable.bg_surface_card)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                dp(260),
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { marginEnd = dp(8) }
        }

        card.addView(TextView(this).apply {
            text = message.artifactType?.uppercase() ?: "FILE"
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(getColor(R.color.status_success))
            background = ContextCompat.getDrawable(context, R.drawable.bg_chip_success)
            setPadding(dp(8), dp(2), dp(8), dp(2))
            contentDescription = "产物类型 ${text}"
        })

        card.addView(TextView(this).apply {
            text = message.title
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_body))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(getColor(R.color.text_primary))
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            contentDescription = "产物文件名 ${message.title}"
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
        })

        card.addView(TextView(this).apply {
            text = message.artifactPath.orEmpty()
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
            setTextColor(getColor(R.color.text_tertiary))
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            contentDescription = "产物路径 ${message.artifactPath.orEmpty()}"
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(2) }
        })

        message.artifactImageBytes?.let { bytes ->
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bitmap != null) {
                card.addView(ImageView(this).apply {
                    setImageBitmap(bitmap)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    contentDescription = "产物图片预览 ${message.title}"
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        dp(84),
                    ).apply {
                        topMargin = dp(10)
                    }
                })
            }
        }

        val preview = message.text.replace(Regex("\\s+"), " ").trim()
        if (message.artifactImageBytes == null && preview.isNotBlank()) {
            card.addView(TextView(this).apply {
                text = preview.take(160) + if (preview.length > 160) "…" else ""
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
                typeface = if ((message.artifactType?.lowercase() ?: "") in CODE_ARTIFACT_TYPES) {
                    android.graphics.Typeface.MONOSPACE
                } else {
                    android.graphics.Typeface.DEFAULT
                }
                setTextColor(getColor(R.color.text_secondary))
                maxLines = 3
                ellipsize = android.text.TextUtils.TruncateAt.END
                contentDescription = "产物预览 ${text}"
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(10) }
            })
        }

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
        }
        actions.addView(galleryAction("打开", "打开产物 ${message.title}") { openArtifact(message) })
        actions.addView(galleryAction("分享", "分享产物 ${message.title}") { shareArtifact(message) })
        actions.addView(
            galleryAction("保存", "保存产物 ${message.title} 到下载目录") {
                downloadArtifact(message)
            },
        )
        actions.addView(
            galleryAction("复制路径", "复制产物路径 ${message.artifactPath.orEmpty()}") {
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(
                    ClipData.newPlainText("Luma artifact path", message.artifactPath.orEmpty()),
                )
                Toast.makeText(this, "已复制产物路径", Toast.LENGTH_SHORT).show()
            },
        )
        card.addView(actions)
        return card
    }

    private fun galleryAction(label: String, description: String, action: () -> Unit): TextView {
        return TextView(this).apply {
            text = label
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(getColor(R.color.accent_primary))
            minHeight = dp(48)
            minWidth = dp(48)
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            contentDescription = description
            isClickable = true
            isFocusable = true
            setOnClickListener { action() }
        }
    }

    private fun showArtifactDialog(message: UiMessage) {
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = dp(20)
            setPadding(pad, pad, pad, pad)
        }
        message.artifactImageBytes?.let { bytes ->
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bitmap != null) {
                body.addView(ImageView(this).apply {
                    setImageBitmap(bitmap)
                    adjustViewBounds = true
                    maxHeight = dp(520)
                    contentDescription = "产物图片 ${message.title}"
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ).apply { bottomMargin = dp(12) }
                })
            }
        }
        body.addView(TextView(this).apply {
            text = buildString {
                append(message.artifactPath ?: "")
                append("\n\n")
                append(message.text)
            }
            setTextIsSelectable(true)
            setTextColor(getColor(R.color.text_primary))
        })
        AlertDialog.Builder(this)
            .setTitle(message.title)
            .setView(body)
            .setPositiveButton("打开") { _, _ -> openArtifact(message) }
            .setNegativeButton("分享") { _, _ -> shareArtifact(message) }
            .setNeutralButton("关闭", null)
            .show()
    }

    private fun openArtifact(message: UiMessage) {
        val documentUri = resolveDocumentUri(message) ?: return
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(documentUri, contentResolver.getType(documentUri) ?: "application/octet-stream")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runCatching { startActivity(intent) }.onFailure {
            Toast.makeText(this, "没有可打开此文件的应用", Toast.LENGTH_SHORT).show()
        }
    }

    private fun shareArtifact(message: UiMessage) {
        val documentUri = resolveDocumentUri(message) ?: return
        val send = Intent(Intent.ACTION_SEND).apply {
            type = contentResolver.getType(documentUri) ?: "application/octet-stream"
            putExtra(Intent.EXTRA_STREAM, documentUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(send, "分享 ${message.title}"))
    }

    private fun downloadArtifact(message: UiMessage) {
        val source = resolveDocumentUri(message) ?: return
        val fileName = message.title.orEmpty()
            .ifBlank { message.artifactPath.orEmpty().substringAfterLast('/') }
            .ifBlank { "luma-artifact" }
        val values = android.content.ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, artifactMimeType(fileName, contentResolver.getType(source)))
            put(
                MediaStore.Downloads.RELATIVE_PATH,
                Environment.DIRECTORY_DOWNLOADS + "/Luma",
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val target = runCatching {
            contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        }.getOrNull() ?: run {
            Toast.makeText(this, "无法创建下载文件", Toast.LENGTH_SHORT).show()
            return
        }
        try {
            contentResolver.openInputStream(source)?.use { input ->
                contentResolver.openOutputStream(target)?.use { output ->
                    input.copyTo(output)
                } ?: throw IllegalStateException("下载文件输出流不可用")
            } ?: throw IllegalStateException("产物文件输入流不可用")
            val complete = android.content.ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            contentResolver.update(target, complete, null, null)
            Toast.makeText(this, "已保存到下载目录/Luma", Toast.LENGTH_SHORT).show()
        } catch (_: Exception) {
            runCatching { contentResolver.delete(target, null, null) }
            Toast.makeText(this, "保存产物失败", Toast.LENGTH_SHORT).show()
        }
    }

    private fun artifactMimeType(fileName: String, detectedType: String?): String {
        return when (fileName.substringAfterLast('.', "").lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "svg" -> "image/svg+xml"
            "pdf" -> "application/pdf"
            "json", "kt", "java", "py", "ts", "tsx", "js", "jsx", "css", "html", "xml", "yml", "yaml", "md", "txt", "csv" -> "text/plain"
            else -> detectedType ?: "application/octet-stream"
        }
    }

    private fun resolveDocumentUri(message: UiMessage): Uri? {
        val tree = workspaceUri() ?: run {
            Toast.makeText(this, "尚未选择项目目录", Toast.LENGTH_SHORT).show()
            return null
        }
        val path = message.artifactPath ?: return null
        return runCatching { SafWorkspaceFileExecutor(this, tree).documentUri(path) }.getOrNull() ?: run {
            Toast.makeText(this, "产物文件不存在或已移除", Toast.LENGTH_SHORT).show()
            null
        }
    }

    private fun pathFrom(args: String, result: String): String? {
        runCatching { return JSONObject(args.ifBlank { "{}" }).optString("path").takeIf { it.isNotBlank() } }
        runCatching { return JSONObject(result.ifBlank { "{}" }).optString("path").takeIf { it.isNotBlank() } }
        return null
    }

    private fun isOnline(): Boolean {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun updateOfflineBanner(online: Boolean) {
        findViewById<TextView>(R.id.offlineBanner).visibility = if (online) {
            View.GONE
        } else {
            View.VISIBLE
        }
    }

    private fun appendStreamDelta(text: String) {
        if (text.isEmpty()) return
        streamBuffer.append(text)
        if (!streamFlushScheduled) {
            streamFlushScheduled = true
            streamHandler.postDelayed({ flushStreaming() }, 80L)
        }
    }

    private fun flushStreaming() {
        if (streamFlushScheduled) {
            streamHandler.removeCallbacksAndMessages(null)
            streamFlushScheduled = false
        }
        val delta = streamBuffer.toString()
        streamBuffer.clear()
        if (delta.isEmpty()) return
        val current = streamingMessage
        val updated = if (current == null) {
            UiMessage(UiMessageRole.ASSISTANT, delta, streaming = true)
        } else {
            current.copy(text = current.text + delta)
        }
        if (current == null) {
            messages += updated
        } else {
            val index = messages.indexOf(current)
            if (index >= 0) messages[index] = updated else messages += updated
        }
        streamingMessage = updated
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        updateContextIndicator()
        scrollToLatest()
    }

    private fun setRunning(running: Boolean) {
        isTaskRunning = running
        findViewById<ProgressBar>(R.id.progress).visibility = if (running) View.VISIBLE else View.GONE
        findViewById<Button>(R.id.startTask).apply {
            visibility = View.VISIBLE
            isEnabled = !running
            alpha = if (running) 0.6f else 1f
        }
        findViewById<Button>(R.id.stopTask).visibility = if (running) View.VISIBLE else View.GONE
        findViewById<EditText>(R.id.taskInput).isEnabled = true
        findViewById<Button>(R.id.taskMode).isEnabled = true
        findViewById<Button>(R.id.agentProfile).isEnabled = true
        findViewById<Button>(R.id.resumeTask).isEnabled = true
        if (!running) findViewById<EditText>(R.id.taskInput).requestFocus()
    }

    private fun scrollToLatest() {
        findViewById<RecyclerView>(R.id.messageList)
            .scrollToPosition((messages.lastIndex).coerceAtLeast(0))
    }

    private fun renderProfile() {
        val profile = profiles.findProfile(currentProfileId)
        currentMode = if (profile == null || profile.mode == AgentProfileMode.ACT) AgentMode.ACT else AgentMode.PLAN
        findViewById<Button>(R.id.taskMode).text = if (currentMode == AgentMode.PLAN) "PLAN" else "ACT"
        val profileButton = findViewById<Button>(R.id.agentProfile)
        profileButton.text = profile?.name ?: "Team"
        profileButton.contentDescription = "当前角色 ${profile?.name ?: "Team"}，点击选择 Agent 角色"
        findViewById<Button>(R.id.taskMode).contentDescription =
            "当前模式 ${if (currentMode == AgentMode.PLAN) "Plan" else "Act"}，点击切换"
    }

    private fun selectProfile(id: String) {
        require(profiles.findProfile(id) != null || id == TEAM_PROFILE_ID) { "Unknown Agent profile" }
        currentProfileId = id
        getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE).edit().putString(AGENT_PROFILE_ID, id).apply()
        renderProfile()
    }

    private fun showProfileSelector() {
        val options = profiles.profiles()
        val labels = options.map { profile ->
            val mode = when (profile.mode) {
                AgentProfileMode.ACT -> "ACT · 可读取和修改工作区"
                AgentProfileMode.PLAN -> "PLAN · 只读分析与规划"
                AgentProfileMode.REVIEW -> "REVIEW · 只读审查与风险检查"
            }
            "${profile.name}  ·  $mode"
        } + "Team  ·  标准角色协同，按交集授权"
        val ids = options.map(AgentProfile::id) + TEAM_PROFILE_ID
        val checkedIndex = ids.indexOf(currentProfileId).coerceAtLeast(0)

        AlertDialog.Builder(this)
            .setTitle("选择 Agent 角色")
            .setSingleChoiceItems(labels.toTypedArray(), checkedIndex) { dialog, which ->
                selectProfile(ids[which])
                dialog.dismiss()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun refreshConfigurationStatus() {
        val workspace = workspaceUri()
        findViewById<TextView>(R.id.workspace).text = if (workspace == null) {
            "尚未选择项目"
        } else {
            "项目：${workspace.lastPathSegment ?: "已授权目录"}"
        }
        val config = AndroidKeyStoreModelConfig(this).load()
        val modelStatus = findViewById<TextView>(R.id.modelStatus)
        modelStatus.text = if (config == null) {
            "模型未配置"
        } else {
            config.model
        }
        modelStatus.setBackgroundResource(
            if (config == null) R.drawable.bg_chip_warning else R.drawable.bg_chip_success,
        )
        modelStatus.setTextColor(
            getColor(
                if (config == null) R.color.status_warning else R.color.status_success,
            ),
        )
        modelStatus.contentDescription = if (config == null) {
            "模型未配置，点击打开模型设置"
        } else {
            "当前模型 ${config.model}，点击修改模型设置"
        }
        modelStatus.isClickable = true
        modelStatus.isFocusable = true
        modelStatus.setOnClickListener { showModelSettingsDialog() }
        val empty = findViewById<TextView>(R.id.emptyState)
        if (messages.isNotEmpty()) {
            empty.visibility = View.GONE
            empty.setOnClickListener(null)
            updateContextIndicator()
            return
        }

        val emptyActionLabel = when {
            config == null -> {
                empty.text = "请先完成模型设置\n在右上角连接模型后再开始任务"
                "连接模型"
            }
            workspace == null -> {
                empty.text = "项目尚未授权\n选择一个项目目录后，Agent 才能读写文件"
                "选择项目"
            }
            else -> {
                empty.text = "开始一个任务\n在下方输入要完成的事情，Agent 会规划并执行"
                "开始任务"
            }
        }
            empty.visibility = View.VISIBLE
            empty.contentDescription = "$emptyActionLabel，${empty.text}"
            empty.setOnClickListener { handleEmptyStateAction() }
        updateContextIndicator()
    }

    private fun handleEmptyStateAction() {
        if (AndroidKeyStoreModelConfig(this).load() == null) {
            showModelSettingsDialog()
            return
        }
        if (workspaceUri() == null) {
            picker.launch(null)
            return
        }
        val input = findViewById<EditText>(R.id.taskInput)
        input.requestFocus()
        getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
            ?.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun updateContextIndicator() {
        val config = AndroidKeyStoreModelConfig(this).load()
        val bar = findViewById<ProgressBar>(R.id.contextBar)
        val text = findViewById<TextView>(R.id.contextText)
        if (config == null || (messages.isEmpty() && attachments.isEmpty())) {
            bar.visibility = View.GONE
            text.visibility = View.GONE
            return
        }
        val window = config.contextWindow.coerceAtLeast(1_000)
        val used = estimatedTokens()
        val percent = (used * 100 / window).coerceIn(0, 100)
        val nearLimit = percent in 80..94
        val overLimit = percent >= 95
        val riskSuffix = when {
            overLimit -> " · 已超限"
            nearLimit -> " · 接近上限"
            else -> ""
        }
        val attachmentSuffix = if (attachments.isEmpty()) {
            ""
        } else {
            " · ${attachments.size} 个附件"
        }
        bar.max = 100
        bar.progress = percent
        bar.progressTintList = ContextCompat.getColorStateList(
            this,
            when {
                overLimit -> R.color.status_error
                nearLimit -> R.color.status_warning
                else -> R.color.accent_primary
            },
        )
        bar.visibility = View.VISIBLE
        text.text = "${formatTokens(used)} / ${formatTokens(window)}$attachmentSuffix$riskSuffix"
        text.contentDescription = when {
            overLimit -> "上下文已超限，使用 ${formatTokens(used)} / ${formatTokens(window)}$attachmentSuffix"
            nearLimit -> "上下文接近上限，使用 ${formatTokens(used)} / ${formatTokens(window)}$attachmentSuffix"
            else -> "上下文使用 ${formatTokens(used)} / ${formatTokens(window)}$attachmentSuffix"
        }
        text.setTextColor(
            getColor(
                when {
                    overLimit -> R.color.status_error
                    nearLimit -> R.color.status_warning
                    else -> R.color.text_tertiary
                },
            ),
        )
        text.visibility = View.VISIBLE
    }

    private fun estimatedTokens(): Int {
        val attachmentTokens = attachments.sumOf { item ->
            (item.name.length + item.preview.take(400).length) / 4
        }
        if (contextTokensFromModel > 0) return contextTokensFromModel + attachmentTokens
        val chars = messages.sumOf { message ->
            message.text.length +
                message.title.orEmpty().length +
                message.toolArgs.orEmpty().length +
                message.toolResult.orEmpty().length
        }
        return ((chars / 4) + attachmentTokens).coerceAtLeast(0)
    }

    private fun formatTokens(value: Int): String =
        if (value >= 1_000) "%.1fk".format(value / 1_000.0)
        else value.toString()

    private fun workspaceUri(): Uri? = getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE)
        .getString(WORKSPACE_URI, null)
        ?.let(Uri::parse)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun showModelSettingsDialog() {
        val store = AndroidKeyStoreModelConfig(this)
        val current = store.load()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (20 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding / 2, padding, 0)
        }
        val endpoint = EditText(this).apply {
            hint = "API 地址，例如 https://api.example.com/v1"
            setText(current?.endpoint.orEmpty())
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
        }
        val model = EditText(this).apply {
            hint = "模型名称"
            setText(current?.model.orEmpty())
        }
        val apiKey = EditText(this).apply {
            hint = if (current?.apiKey.isNullOrBlank()) "API Key" else "API Key（留空则保留现有密钥）"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val contextWindow = EditText(this).apply {
            hint = "上下文窗口 Token 数（默认 128000）"
            setText((current?.contextWindow ?: ModelConfig.DEFAULT_CONTEXT_WINDOW).toString())
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
        }
        container.addView(endpoint)
        container.addView(model)
        container.addView(apiKey)
        container.addView(contextWindow)

        val dialog = AlertDialog.Builder(this)
            .setTitle("模型设置")
            .setView(container)
            .setNegativeButton("取消", null)
            .setPositiveButton("保存", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val endpointValue = endpoint.text.toString().trim().trimEnd('/')
                val modelValue = model.text.toString().trim()
                val keyValue = apiKey.text.toString().trim().ifBlank { current?.apiKey.orEmpty() }
                if (!endpointValue.startsWith("https://") && !endpointValue.startsWith("http://")) {
                    endpoint.error = "请输入有效的 HTTP(S) API 地址"
                    return@setOnClickListener
                }
                if (modelValue.isBlank()) {
                    model.error = "请输入模型名称"
                    return@setOnClickListener
                }
                if (keyValue.isBlank()) {
                    apiKey.error = "请输入 API Key"
                    return@setOnClickListener
                }
                val contextWindowValue = contextWindow.text.toString().trim().toIntOrNull()
                if (contextWindowValue == null || contextWindowValue < 1_000 || contextWindowValue > 10_000_000) {
                    contextWindow.error = "请输入 1000 - 10000000 之间的数字"
                    return@setOnClickListener
                }
                runCatching { store.save(ModelConfig(endpointValue, modelValue, keyValue, contextWindowValue)) }
                    .onSuccess {
                        Toast.makeText(this, "模型设置已安全保存", Toast.LENGTH_SHORT).show()
                        hideSetupIssue()
                        refreshConfigurationStatus()
                        dialog.dismiss()
                    }
                    .onFailure {
                        Toast.makeText(this, "保存失败：${it.message ?: "未知错误"}", Toast.LENGTH_LONG).show()
                    }
            }
        }
        dialog.show()
    }

    companion object {
        const val PUBLIC_CONFIG = "public_config"
        const val WORKSPACE_URI = "workspace_uri"
        const val AGENT_PROFILE_ID = "agent_profile_id"
        const val TEAM_PROFILE_ID = "bundle:standard"
        private val ARTIFACT_TOOLS = setOf(
            "apply_patch", "create_file", "overwrite_file", "append_file", "rollback_file",
        )
        private val CODE_ARTIFACT_TYPES = setOf(
            "c", "cc", "cpp", "css", "csv", "go", "gradle", "h", "hpp", "html", "java", "js",
            "json", "jsx", "kt", "kts", "md", "php", "py", "rb", "rs", "sh", "sql", "swift",
            "ts", "tsx", "xml", "yaml", "yml",
        )
    }
}
