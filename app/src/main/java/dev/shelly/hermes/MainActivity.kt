package dev.shelly.hermes

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
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
            renderTaskState(state, detail, activeTaskId, queueCount, toolName, toolCallId, toolState)
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_main)

        messages = mutableListOf()
        messageAdapter = AgentMessageAdapter(this, messages)
        findViewById<RecyclerView>(R.id.messageList).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = messageAdapter
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
        val input = findViewById<EditText>(R.id.taskInput)
        val prompt = input.text.toString().trim()
        if (prompt.isBlank()) {
            input.error = "请输入任务内容"
            return
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

        lastPrompt = prompt
        flushStreaming()
        streamingMessage = null
        appendMessage(UiMessageRole.USER, prompt)
        input.text.clear()
        findViewById<View>(R.id.errorContainer).visibility = View.GONE

        val intent = Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_START
            putExtra(TaskForegroundService.EXTRA_TASK_ID, "task-${System.currentTimeMillis()}")
            putExtra(TaskForegroundService.EXTRA_PROMPT, prompt)
            putExtra(TaskForegroundService.EXTRA_MODE, currentMode.wireValue)
            putExtra(TaskForegroundService.EXTRA_PROFILE_ID, currentProfileId)
        }
        ContextCompat.startForegroundService(this, intent)
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
    ) {
        if (queueCount >= 0) findViewById<Button>(R.id.taskQueue).text = "任务 $queueCount"
        findViewById<TextView>(R.id.taskStatus).apply {
            text = detail.ifBlank { stateDescription(state) }
            visibility = if (
                state == TaskState.COMPLETED.name || state == TaskState.FAILED.name ||
                state == TaskState.STOPPED.name || state == TaskForegroundService.STATE_QUEUE_UPDATED && activeTaskId.isBlank() && queueCount == 0
            ) View.GONE else View.VISIBLE
        }
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
                    "RUNNING" -> appendToolMessage(toolName, toolCallId, detail, toolState)
                    "FINISHED", "FAILED" -> updateToolMessage(toolCallId, detail, toolState)
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
                findViewById<TextView>(R.id.errorText).text = detail.ifBlank { "任务执行失败" }
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

    private fun appendMessage(role: UiMessageRole, text: String) {
        flushStreaming()
        messages += UiMessage(role, text)
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        scrollToLatest()
    }

    private fun appendToolMessage(toolName: String, toolCallId: String, detail: String, state: String) {
        if (toolName.isBlank()) return
        flushStreaming()
        streamingMessage = null
        messages += UiMessage(
            role = UiMessageRole.TOOL,
            text = detail,
            title = toolName,
            toolCallId = toolCallId,
            toolState = state,
        )
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        scrollToLatest()
    }

    private fun updateToolMessage(toolCallId: String, detail: String, state: String) {
        if (toolCallId.isBlank()) return
        val index = messages.indexOfLast { it.role == UiMessageRole.TOOL && it.toolCallId == toolCallId }
        if (index < 0) return
        messages[index] = messages[index].copy(text = detail, toolState = state)
        messageAdapter.notifyDataSetChanged()
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
    }

    private fun workspaceUri(): Uri? = getSharedPreferences(PUBLIC_CONFIG, MODE_PRIVATE)
        .getString(WORKSPACE_URI, null)
        ?.let(Uri::parse)

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
        container.addView(endpoint)
        container.addView(model)
        container.addView(apiKey)

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
                runCatching { store.save(ModelConfig(endpointValue, modelValue, keyValue)) }
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
    }
}
