package dev.shelly.hermes

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import java.text.DateFormat
import java.util.Date

/** Local durable queue management. Mutations are routed through the foreground service. */
class TaskQueueActivity : Activity() {
    private lateinit var store: AgentTaskQueueStore
    private lateinit var list: LinearLayout
    private lateinit var empty: View
    private lateinit var scroll: ScrollView
    private lateinit var summary: TextView
    private lateinit var errorContainer: LinearLayout
    private lateinit var errorText: TextView

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_task_queue)
        store = AgentTaskQueueStore(this)
        list = findViewById(R.id.taskQueueList)
        empty = findViewById(R.id.taskQueueEmpty)
        scroll = findViewById(R.id.taskQueueScroll)
        summary = findViewById(R.id.taskQueueSummary)
        errorContainer = findViewById(R.id.taskQueueError)
        errorText = findViewById(R.id.taskQueueErrorText)
        findViewById<Button>(R.id.refreshTaskQueue).setOnClickListener { render() }
        findViewById<Button>(R.id.taskQueueErrorRetry).apply {
            contentDescription = "重试读取任务队列"
            setOnClickListener { render() }
        }
        findViewById<Button>(R.id.startNewTaskFromQueue).setOnClickListener { finish() }
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        list.removeAllViews()
        runCatching { store.list().sortedByDescending { it.createdAt } }.fold(
            onSuccess = { tasks ->
                errorContainer.visibility = View.GONE
                empty.visibility = if (tasks.isEmpty()) View.VISIBLE else View.GONE
                scroll.visibility = if (tasks.isEmpty()) View.GONE else View.VISIBLE
                val pending = tasks.count { it.state == QueuedTaskState.PENDING }
                val running = tasks.count { it.state == QueuedTaskState.RUNNING }
                summary.text = "${tasks.size} 项任务 · $running 项运行 · $pending 项等待"
                summary.contentDescription = summary.text
                tasks.forEach { list.addView(card(it)) }
            },
            onFailure = { error ->
                empty.visibility = View.GONE
                scroll.visibility = View.GONE
                errorContainer.visibility = View.VISIBLE
                errorText.text = "无法读取任务队列：${error.message ?: "未知错误"}"
                errorText.contentDescription = "任务队列读取失败。${errorText.text}"
                summary.text = "读取失败"
                summary.contentDescription = summary.text
            },
        )
    }

    private fun card(task: QueuedAgentTask): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = ContextCompat.getDrawable(context, R.drawable.bg_surface_card)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(10) }

        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_SectionTitle)
            text = task.prompt.ifBlank { task.id }
            maxLines = 3
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        addView(TextView(context).apply {
            text = stateLabel(task.state)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, resources.getDimension(R.dimen.type_micro))
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(getColor(stateColor(task.state)))
            background = ContextCompat.getDrawable(context, stateBackground(task.state))
            setPadding(dp(10), dp(4), dp(10), dp(4))
            contentDescription = "任务状态 ${stateLabel(task.state)}"
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
        })
        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Body)
            setPadding(0, dp(6), 0, 0)
            text = buildString {
                append(task.profileId)
                append(" · 尝试 ")
                append(task.attempts)
                append(" 次\n")
                append(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(task.createdAt)))
                if (task.detail.isNotBlank()) append("\n${task.detail}")
            }
        })
        when (task.state) {
            QueuedTaskState.PENDING -> addView(actionButton("取消排队") { cancel(task.id) })
            QueuedTaskState.FAILED, QueuedTaskState.CANCELLED -> addView(actionButton("重新排队") { retry(task.id) })
            else -> Unit
        }
    }

    private fun actionButton(label: String, action: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        background = ContextCompat.getDrawable(this@TaskQueueActivity, R.drawable.bg_button_secondary)
        setTextColor(getColor(R.color.text_primary))
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(48),
        ).apply { topMargin = dp(10) }
        contentDescription = label
    }

    private fun cancel(id: String) {
        startService(Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_CANCEL_QUEUED
            putExtra(TaskForegroundService.EXTRA_TASK_ID, id)
        })
        Toast.makeText(this, "已请求取消", Toast.LENGTH_SHORT).show()
        window.decorView.postDelayed({ render() }, 250)
    }

    private fun retry(id: String) {
        startService(Intent(this, TaskForegroundService::class.java).apply {
            action = TaskForegroundService.ACTION_RETRY_QUEUED
            putExtra(TaskForegroundService.EXTRA_TASK_ID, id)
        })
        Toast.makeText(this, "已重新加入队列", Toast.LENGTH_SHORT).show()
        window.decorView.postDelayed({ render() }, 250)
    }

    private fun stateLabel(state: QueuedTaskState): String = when (state) {
        QueuedTaskState.PENDING -> "等待中"
        QueuedTaskState.RUNNING -> "运行中"
        QueuedTaskState.COMPLETED -> "已完成"
        QueuedTaskState.FAILED -> "失败"
        QueuedTaskState.CANCELLED -> "已取消"
    }

    private fun stateBackground(state: QueuedTaskState): Int = when (state) {
        QueuedTaskState.PENDING -> R.drawable.bg_chip_warning
        QueuedTaskState.RUNNING -> R.drawable.bg_chip_running
        QueuedTaskState.COMPLETED -> R.drawable.bg_chip_success
        QueuedTaskState.FAILED -> R.drawable.bg_chip_error
        QueuedTaskState.CANCELLED -> R.drawable.bg_chip
    }

    private fun stateColor(state: QueuedTaskState): Int = when (state) {
        QueuedTaskState.PENDING -> getColor(R.color.status_warning)
        QueuedTaskState.RUNNING -> getColor(R.color.accent_primary)
        QueuedTaskState.COMPLETED -> getColor(R.color.status_success)
        QueuedTaskState.FAILED -> getColor(R.color.status_error)
        QueuedTaskState.CANCELLED -> getColor(R.color.text_secondary)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
