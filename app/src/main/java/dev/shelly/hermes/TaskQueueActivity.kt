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
import java.text.DateFormat
import java.util.Date

/** Local durable queue management. Mutations are routed through the foreground service. */
class TaskQueueActivity : Activity() {
    private lateinit var store: AgentTaskQueueStore
    private lateinit var list: LinearLayout
    private lateinit var empty: TextView
    private lateinit var scroll: ScrollView
    private lateinit var summary: TextView

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_task_queue)
        store = AgentTaskQueueStore(this)
        list = findViewById(R.id.taskQueueList)
        empty = findViewById(R.id.taskQueueEmpty)
        scroll = findViewById(R.id.taskQueueScroll)
        summary = findViewById(R.id.taskQueueSummary)
        findViewById<Button>(R.id.refreshTaskQueue).setOnClickListener { render() }
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun render() {
        val tasks = runCatching { store.list() }.getOrElse {
            Toast.makeText(this, "读取任务队列失败：${it.message}", Toast.LENGTH_LONG).show()
            emptyList()
        }.sortedByDescending { it.createdAt }
        list.removeAllViews()
        empty.visibility = if (tasks.isEmpty()) View.VISIBLE else View.GONE
        scroll.visibility = if (tasks.isEmpty()) View.GONE else View.VISIBLE
        val pending = tasks.count { it.state == QueuedTaskState.PENDING }
        val running = tasks.count { it.state == QueuedTaskState.RUNNING }
        summary.text = "${tasks.size} 项任务 · $running 项运行 · $pending 项等待"
        tasks.forEach { list.addView(card(it)) }
    }

    private fun card(task: QueuedAgentTask): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(getColor(R.color.surface_glass))
        setPadding(dp(16), dp(14), dp(16), dp(14))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(10) }

        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_SectionTitle)
            text = task.prompt.ifBlank { task.id }
        })
        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Body)
            setPadding(0, dp(6), 0, 0)
            text = buildString {
                append(stateLabel(task.state))
                append(" · ")
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
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(48),
        ).apply { topMargin = dp(10) }
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

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
