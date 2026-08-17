package dev.shelly.hermes

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import dev.shelly.hermes.core.AgentProfileMode
import dev.shelly.hermes.core.AgentProfileRegistry

class MainActivity : ComponentActivity() {
    private lateinit var messages: MutableList<UiMessage>
    private lateinit var messageAdapter: AgentMessageAdapter
    private val profiles = AgentProfileRegistry()
    private var lastPrompt: String = ""
    private var currentMode: AgentMode = AgentMode.ACT
    private var currentProfileId: String = "coding"

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
            renderTaskState(state, detail, activeTaskId, queueCount)
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_main)

        messages = mutableListOf()
        messageAdapter = AgentMessageAdapter(this, messages)
        findViewById<ListView>(R.id.messageList).adapter = messageAdapter

        findViewById<Button>(R.id.chooseWorkspace).setOnClickListener { picker.launch(null) }
        findViewById<Button>(R.id.capabilities).setOnClickListener {
            startActivity(Intent(this, CapabilitiesActivity::class.java))
        }
        findViewById<Button>(R.id.history).setOnClickListener {
            startActivity(Intent(this, HistoryActivity::class.java))
        }
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

    private fun renderTaskState(state: String, detail: String, activeTaskId: String, queueCount: Int) {
        if (queueCount >= 0) findViewById<Button>(R.id.taskQueue).text = "任务 $queueCount"
        findViewById<TextView>(R.id.taskStatus).apply {
            text = detail.ifBlank { stateDescription(state) }
            visibility = if (
                state == TaskState.COMPLETED.name || state == TaskState.FAILED.name ||
                state == TaskState.STOPPED.name || state == TaskForegroundService.STATE_QUEUE_UPDATED && activeTaskId.isBlank() && queueCount == 0
            ) View.GONE else View.VISIBLE
        }
        when (state) {
            TaskState.STARTING.name, TaskState.RUNNING.name -> setRunning(true)
            TaskForegroundService.STATE_QUEUED -> appendMessage(UiMessageRole.STATUS, "任务已加入执行队列")
            TaskForegroundService.STATE_QUEUE_UPDATED -> setRunning(activeTaskId.isNotBlank())
            TaskForegroundService.STATE_AWAITING_APPROVAL -> {
                setRunning(true)
                findViewById<Button>(R.id.approval).visibility = View.VISIBLE
                startActivity(Intent(this, ApprovalActivity::class.java))
            }
            TaskState.COMPLETED.name -> {
                setRunning(false)
                findViewById<Button>(R.id.approval).visibility = View.GONE
                appendMessage(UiMessageRole.ASSISTANT, detail.ifBlank { "任务已完成" })
            }
            TaskState.STOPPED.name, TaskState.CANCELLING.name, TaskState.STOPPING.name -> {
                setRunning(state == TaskState.CANCELLING.name || state == TaskState.STOPPING.name)
                if (state == TaskState.STOPPED.name) appendMessage(UiMessageRole.STATUS, "任务已停止")
            }
            TaskState.FAILED.name -> {
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
        messages += UiMessage(role, text)
        messageAdapter.notifyDataSetChanged()
        findViewById<View>(R.id.emptyState).visibility = View.GONE
        findViewById<ListView>(R.id.messageList).setSelection(messages.lastIndex)
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
