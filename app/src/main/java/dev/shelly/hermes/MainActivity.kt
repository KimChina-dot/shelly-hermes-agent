package dev.shelly.hermes

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
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
            Toast.makeText(this, "无法保留目录权限，请重新选择项目目录", Toast.LENGTH_LONG).show()
            return@registerForActivityResult
        }
        getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE)
            .edit()
            .putString(WORKSPACE_URI, uri.toString())
            .apply()
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

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_main)

        messages = mutableListOf()
        messageAdapter = AgentMessageAdapter(this, messages) { retryLastTask() }
        findViewById<RecyclerView>(R.id.messageList).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = messageAdapter
            itemAnimator = DefaultItemAnimator().apply {
                addDuration = 200L
                changeDuration = 200L
                moveDuration = 200L
                removeDuration = 200L
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
            val available = profiles.profiles().map { it.id } + TEAM_PROFILE_ID
            val index = available.indexOf(currentProfileId).coerceAtLeast(0)
            selectProfile(available[(index + 1) % available.size])
        }
        findViewById<Button>(R.id.startTask).setOnClickListener { startTask() }
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
    }

    override fun onStop() {
        unregisterReceiver(taskStatusReceiver)
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
            Toast.makeText(this, "请先选择项目目录", Toast.LENGTH_SHORT).show()
            return
        }
        if (AndroidKeyStoreModelConfig(this).load() == null) {
            Toast.makeText(this, "请先完成模型设置", Toast.LENGTH_SHORT).show()
            showModelSettingsDialog()
            return
        }
        if (!isOnline()) {
            findViewById<View>(R.id.errorContainer).visibility = View.VISIBLE
            findViewById<TextView>(R.id.errorText).text = "网络离线，请检查连接后重试"
            return
        }

        lastPrompt = prompt
        flushStreaming()
        streamingMessage = null
        appendMessage(UiMessageRole.USER, prompt)
        input.text.clear()
        findViewById<View>(R.id.errorContainer).visibility = View.GONE

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
        if (lastPrompt.isBlank()) return
        appendMessage(UiMessageRole.STATUS, "正在重试上次任务")
        findViewById<EditText>(R.id.taskInput).setText(lastPrompt)
        startTask()
    }

    private fun stopTask() {
        startService(Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_STOP
        })
    }

    private fun resumeTask() {
        val durableSession = FileSessionStore(this).list().firstOrNull { session ->
            runCatching { SessionEventStore(this, session.id).hasCheckpoint() }.getOrDefault(false)
        }
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
        findViewById<TextView>(R.id.taskStatus).apply {
            text = detail.ifBlank { stateDescription(state) }
            visibility = if (
                state == TaskState.COMPLETED.name || state == TaskState.FAILED.name ||
                state == TaskState.STOPPED.name || state == TaskForegroundService.STATE_QUEUE_UPDATED && activeTaskId.isBlank() && queueCount == 0
            ) View.GONE else View.VISIBLE
        }
        updateTaskTimeline(state, detail, toolState, activeTaskId)
        when (state) {
            TaskState.STARTING.name -> setRunning(true)
            TaskForegroundService.STATE_MODEL_DELTA -> appendStreamDelta(detail)
            TaskForegroundService.STATE_QUEUED -> appendMessage(UiMessageRole.STATUS, "任务已加入执行队列")
            TaskForegroundService.STATE_QUEUE_UPDATED -> setRunning(activeTaskId.isNotBlank())
            TaskForegroundService.STATE_AWAITING_APPROVAL -> {
                flushStreaming()
                setRunning(true)
                findViewById<Button>(R.id.approval).visibility = View.VISIBLE
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
                findViewById<View>(R.id.errorContainer).visibility = View.VISIBLE
                val normalized = detail.lowercase()
                findViewById<TextView>(R.id.errorText).text = if ("context" in normalized || "token" in normalized) {
                    "上下文过长或超出模型限制：${detail.ifBlank { "请求超出可用上下文" }}"
                } else {
                    detail.ifBlank { "任务执行失败" }
                }
            }
        }
    }

    private fun stateDescription(state: String): String = when (state) {
        TaskState.STARTING.name -> "任务启动中"
        TaskState.RUNNING.name -> "任务执行中"
        TaskState.STOPPING.name -> "任务停止中"
        TaskState.CANCELLING.name -> "任务取消中"
        TaskForegroundService.STATE_AWAITING_APPROVAL -> "等待审批"
        else -> state
    }

    private fun updateTaskTimeline(
        state: String,
        detail: String,
        toolState: String,
        activeTaskId: String,
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
                modelState = timelineModelState
                toolPhaseState = timelineToolState
                approvalState = timelineApprovalState
                resultState = "PENDING"
            }
            TaskForegroundService.STATE_AWAITING_APPROVAL -> {
                timelineModelState = "FINISHED"
                timelineToolState = "FINISHED"
                timelineApprovalState = "WAITING_FOR_APPROVAL"
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
                    }
                    toolState == "FINISHED" || toolState == "FAILED" -> {
                        timelineModelState = "FINISHED"
                        timelineToolState = toolState
                    }
                    detail.startsWith("模型响应耗时") -> {
                        timelineModelState = "FINISHED"
                        timelineToolState = "PENDING"
                    }
                    else -> {
                        timelineModelState = "RUNNING"
                        timelineToolState = "PENDING"
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
        bindTimelineStep(R.id.timelineTool, "工具", toolPhaseState)
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
        messages += UiMessage(
            role = UiMessageRole.TOOL,
            text = detail,
            title = toolName,
            toolCallId = toolCallId,
            toolState = state,
            toolStartedAtMillis = startedAtMillis,
            toolArgs = args,
        )
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
            Toast.makeText(this, "无法读取附件内容，请选择文本类文件", Toast.LENGTH_SHORT).show()
            return
        }
        attachments += AttachmentRef(name, preview)
        renderAttachmentTray()
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
                text = item.name
                textSize = 12f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                setTextColor(getColor(R.color.text_primary))
                background = ContextCompat.getDrawable(context, R.drawable.bg_chip_warning)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                contentDescription = "附件 ${item.name}，点击移除"
                setOnClickListener {
                    attachments.removeAt(index)
                    renderAttachmentTray()
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
            list.addView(TextView(this).apply {
                text = "${message.artifactType?.uppercase() ?: "FILE"} · ${message.title}"
                textSize = 12f
                typeface = android.graphics.Typeface.DEFAULT_BOLD
                setTextColor(getColor(R.color.text_primary))
                background = ContextCompat.getDrawable(context, R.drawable.bg_chip_success)
                setPadding(dp(10), dp(4), dp(10), dp(4))
                contentDescription = "产物 ${message.title}"
                setOnClickListener { showArtifactDialog(message) }
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply { marginEnd = dp(8) }
            })
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
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
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
        findViewById<ProgressBar>(R.id.progress).visibility = if (running) View.VISIBLE else View.GONE
        findViewById<Button>(R.id.startTask).visibility = View.VISIBLE
        findViewById<Button>(R.id.stopTask).visibility = if (running) View.VISIBLE else View.GONE
        findViewById<EditText>(R.id.taskInput).isEnabled = true
        findViewById<Button>(R.id.taskMode).isEnabled = true
        findViewById<Button>(R.id.agentProfile).isEnabled = true
        findViewById<Button>(R.id.resumeTask).isEnabled = true
    }

    private fun scrollToLatest() {
        findViewById<RecyclerView>(R.id.messageList)
            .scrollToPosition((messages.lastIndex).coerceAtLeast(0))
    }

    private fun renderProfile() {
        val profile = profiles.findProfile(currentProfileId)
        currentMode = if (profile == null || profile.mode == AgentProfileMode.ACT) AgentMode.ACT else AgentMode.PLAN
        findViewById<Button>(R.id.taskMode).text = if (currentMode == AgentMode.PLAN) "PLAN" else "ACT"
        findViewById<Button>(R.id.agentProfile).text = profile?.name ?: "Team"
    }

    private fun selectProfile(id: String) {
        require(profiles.findProfile(id) != null || id == TEAM_PROFILE_ID) { "Unknown Agent profile" }
        currentProfileId = id
        getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE).edit().putString(AGENT_PROFILE_ID, id).apply()
        renderProfile()
    }

    private fun refreshConfigurationStatus() {
        val workspace = workspaceUri()
        findViewById<TextView>(R.id.workspace).text = if (workspace == null) {
            "尚未选择项目"
        } else {
            "项目：${workspace.lastPathSegment ?: "已授权目录"}"
        }
        val config = AndroidKeyStoreModelConfig(this).load()
        findViewById<TextView>(R.id.modelStatus).text = if (config == null) {
            "模型未连接"
        } else {
            "模型：${config.model}"
        }
        val empty = findViewById<TextView>(R.id.emptyState)
        if (messages.isEmpty() && workspace == null) {
            empty.text = "首次使用请先连接模型\n1. 点击右上角设置，填入模型地址与密钥\n2. 点击“项目”选择授权目录\n3. 在下方输入要完成的任务"
        } else if (messages.isEmpty() && config == null) {
            empty.text = "请先完成模型设置\n在右上角连接模型后再开始任务"
        } else if (messages.isEmpty()) {
            empty.text = "开始一个任务\n在下方输入要完成的事情，Agent 会规划并执行"
        }
        updateContextIndicator()
    }

    private fun updateContextIndicator() {
        val config = AndroidKeyStoreModelConfig(this).load()
        val bar = findViewById<ProgressBar>(R.id.contextBar)
        val text = findViewById<TextView>(R.id.contextText)
        if (config == null || messages.isEmpty()) {
            bar.visibility = View.GONE
            text.visibility = View.GONE
            return
        }
        val window = config.contextWindow.coerceAtLeast(1_000)
        val used = estimatedTokens()
        val percent = (used * 100 / window).coerceIn(0, 100)
        val warning = percent >= 80
        bar.max = 100
        bar.progress = percent
        bar.progressTintList = ContextCompat.getColorStateList(
            this,
            if (warning) R.color.status_error else R.color.accent_primary,
        )
        bar.visibility = View.VISIBLE
        text.text = "${formatTokens(used)} / ${formatTokens(window)}"
        text.setTextColor(getColor(if (warning) R.color.status_error else R.color.text_tertiary))
        text.visibility = View.VISIBLE
    }

    private fun estimatedTokens(): Int {
        if (contextTokensFromModel > 0) return contextTokensFromModel
        val chars = messages.sumOf { message ->
            message.text.length +
                message.title.orEmpty().length +
                message.toolArgs.orEmpty().length +
                message.toolResult.orEmpty().length
        }
        return (chars / 4).coerceAtLeast(0)
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
    }
}
