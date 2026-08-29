package dev.shelly.hermes

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import java.text.DateFormat
import java.util.Date

/** A local task timeline with explicit resume and event-fork actions. */
class HistoryActivity : Activity() {
    private lateinit var store: SessionStore
    private lateinit var emptyState: TextView
    private lateinit var historyList: LinearLayout
    private lateinit var historyScroll: ScrollView
    private lateinit var clearButton: Button
    private lateinit var historySummary: TextView

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_history)
        store = FileSessionStore(this)
        emptyState = findViewById(R.id.historyEmptyState)
        historyList = findViewById(R.id.historyList)
        historyScroll = findViewById(R.id.historyScroll)
        clearButton = findViewById(R.id.clearHistoryButton)
        clearButton.background = ContextCompat.getDrawable(this, R.drawable.bg_button_danger)
        historySummary = findViewById(R.id.historySummary)
        clearButton.contentDescription = getString(R.string.clear_history_content)
        clearButton.setOnClickListener {
            confirmClearHistory()
        }
    }

    override fun onResume() {
        super.onResume()
        renderHistory()
    }

    private fun renderHistory() {
        val sessions = store.list()
        historyList.removeAllViews()
        emptyState.visibility = if (sessions.isEmpty()) View.VISIBLE else View.GONE
        historyScroll.visibility = if (sessions.isEmpty()) View.GONE else View.VISIBLE
        clearButton.isEnabled = sessions.isNotEmpty()
        historySummary.text = if (sessions.isEmpty()) {
            "会话事件保存在本机，可随时恢复或创建分支"
        } else {
            "${sessions.size} 个本地会话 · 可恢复或从指定事件创建分支"
        }
        sessions.forEach { historyList.addView(createSessionCard(it)) }
    }

    private fun createSessionCard(session: Session): LinearLayout = LinearLayout(this).apply {
        val eventStore = SessionEventStore(this@HistoryActivity, session.id)
        val events = runCatching { eventStore.load() }.getOrDefault(emptyList())
        val maxSequence = events.lastOrNull()?.sequence ?: 0L
        val messages = runCatching { eventStore.deriveMessages() }.getOrDefault(emptyList())
        val checkpoint = runCatching { eventStore.latestCheckpoint() }.getOrNull()
        orientation = LinearLayout.VERTICAL
        background = ContextCompat.getDrawable(context, R.drawable.bg_surface_card)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(10) }

        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_SectionTitle)
            text = session.prompt.ifBlank { "未命名任务" }
        })
        addView(TextView(context).apply {
            text = statusLabel(session.status)
            textSize = 12f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setTextColor(getColor(statusColor(session.status)))
            background = ContextCompat.getDrawable(context, statusBackground(session.status))
            contentDescription = "任务状态 ${statusLabel(session.status)}"
            setPadding(dp(10), dp(4), dp(10), dp(4))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
        })
        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Caption)
            setPadding(0, dp(4), 0, 0)
            text = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                .format(Date(session.updatedAt))
        })
        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Body)
            setPadding(0, dp(10), 0, 0)
            text = buildString {
                append("事件摘要：")
                append(session.summary.ifBlank { "旧版会话暂无事件摘要，可继续恢复此任务。" })
                if (maxSequence > 0L) append("\n事件：$maxSequence 条")
                if (messages.isNotEmpty()) append("\n消息：${messages.size} 条")
                append(
                    when {
                        checkpoint != null -> "\n检查点：可从此处恢复"
                        messages.isNotEmpty() -> "\n检查点：无，可查看回放"
                        else -> "\n检查点：无"
                    },
                )
            }
        })
        val transcript = TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Body)
            setPadding(0, dp(10), 0, 0)
            visibility = View.GONE
            text = if (messages.isEmpty()) {
                "此会话暂无可回放消息"
            } else {
                messages.joinToString("\n\n") { message ->
                    val role = when (message.role) {
                        dev.shelly.hermes.core.MessageRole.SYSTEM -> "系统"
                        dev.shelly.hermes.core.MessageRole.USER -> "你"
                        dev.shelly.hermes.core.MessageRole.ASSISTANT -> "Luma"
                        dev.shelly.hermes.core.MessageRole.TOOL -> "工具"
                    }
                    "[$role] ${message.content}"
                }
            }
        }
        transcript.setTextColor(getColor(R.color.text_secondary))
        addView(Button(context).apply {
            text = "查看完整会话"
            isAllCaps = false
            background = ContextCompat.getDrawable(context, R.drawable.bg_button_secondary)
            setTextColor(getColor(R.color.text_primary))
            isEnabled = messages.isNotEmpty()
            setOnClickListener {
                val showing = transcript.visibility == View.VISIBLE
                transcript.visibility = if (showing) View.GONE else View.VISIBLE
                text = if (showing) "查看完整会话" else "收起完整会话"
            }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(48),
        ).apply { topMargin = dp(10) })
        addView(transcript)
        val timelineEvents = events.filterNot {
            it.event.type == SessionEventType.MODEL_DELTA || it.event.type == SessionEventType.CHECKPOINT
        }
        val timelineContainer = LinearLayout(this@HistoryActivity).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            background = ContextCompat.getDrawable(context, R.drawable.bg_surface_card)
            setPadding(dp(14), dp(12), dp(14), dp(12))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(10) }
        }
        timelineEvents.forEachIndexed { index, envelope ->
            val isLast = index == timelineEvents.lastIndex
            timelineContainer.addView(LinearLayout(this@HistoryActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                addView(TextView(context).apply {
                    text = "●"
                    textSize = 10f
                    setTextColor(getColor(R.color.accent_primary))
                })
                addView(TextView(context).apply {
                    text = timelineLabel(envelope.event.type)
                    textSize = 13f
                    setTextColor(getColor(R.color.text_primary))
                    setPadding(dp(8), 0, dp(8), 0)
                }, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    1f,
                ))
                addView(TextView(context).apply {
                    text = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(envelope.timestamp))
                    textSize = 12f
                    setTextColor(getColor(R.color.text_tertiary))
                })
                if (!isLast) {
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ).apply { bottomMargin = dp(8) }
                }
            })
        }
        addView(timelineContainer)
        addView(Button(this@HistoryActivity).apply {
            text = "查看执行时间线"
            isAllCaps = false
            background = ContextCompat.getDrawable(context, R.drawable.bg_button_secondary)
            setTextColor(getColor(R.color.text_primary))
            isEnabled = timelineEvents.isNotEmpty()
            setOnClickListener {
                val showing = timelineContainer.visibility == View.VISIBLE
                timelineContainer.visibility = if (showing) View.GONE else View.VISIBLE
                text = if (showing) "查看执行时间线" else "收起执行时间线"
            }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(48),
        ).apply { topMargin = dp(10) })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, 0)
            addView(Button(context).apply {
                text = "恢复"
                isAllCaps = false
                background = ContextCompat.getDrawable(context, R.drawable.bg_button_secondary)
                setTextColor(getColor(R.color.text_primary))
                contentDescription = "恢复会话 ${session.prompt.ifBlank { session.id }}"
                setOnClickListener { resumeSession(session) }
            }, actionLayoutParams())
            addView(Button(context).apply {
                text = "从事件分叉"
                isAllCaps = false
                background = ContextCompat.getDrawable(context, R.drawable.bg_button_secondary)
                setTextColor(getColor(R.color.text_primary))
                isEnabled = maxSequence > 0L
                contentDescription = "从指定事件创建会话分支"
                setOnClickListener { showForkDialog(session, maxSequence) }
            }, actionLayoutParams(startMargin = dp(8)))
        })
    }

    private fun timelineLabel(type: SessionEventType): String = when (type) {
        SessionEventType.SESSION_STARTED -> "任务启动"
        SessionEventType.STATUS -> "状态更新"
        SessionEventType.MODEL_STARTED -> "请求模型"
        SessionEventType.MODEL_FINISHED -> "模型响应完成"
        SessionEventType.APPROVAL_WAITING -> "等待审批"
        SessionEventType.APPROVAL_FINISHED -> "审批完成"
        SessionEventType.TOOL_STARTED -> "工具开始"
        SessionEventType.TOOL_FINISHED -> "工具完成"
        SessionEventType.FORKED -> "创建分支"
        SessionEventType.MIGRATED_CHECKPOINT -> "迁移检查点"
        SessionEventType.CHECKPOINT -> "检查点"
        SessionEventType.MODEL_DELTA -> "流式输出"
    }

    private fun statusLabel(status: String): String = when (status.uppercase()) {
        "RUNNING", "STARTING" -> "运行中"
        "AWAITING_APPROVAL", "WAITING_FOR_APPROVAL" -> "等待审批"
        "COMPLETED" -> "已完成"
        "STOPPED" -> "已停止"
        "FAILED" -> "失败"
        else -> "历史记录"
    }

    private fun statusBackground(status: String): Int = when (status.uppercase()) {
        "RUNNING", "STARTING" -> R.drawable.bg_chip_running
        "AWAITING_APPROVAL", "WAITING_FOR_APPROVAL" -> R.drawable.bg_chip_warning
        "COMPLETED" -> R.drawable.bg_chip_success
        "STOPPED" -> R.drawable.bg_chip
        "FAILED" -> R.drawable.bg_chip_error
        else -> R.drawable.bg_chip
    }

    private fun statusColor(status: String): Int = when (status.uppercase()) {
        "RUNNING", "STARTING" -> getColor(R.color.accent_primary)
        "AWAITING_APPROVAL", "WAITING_FOR_APPROVAL" -> getColor(R.color.status_warning)
        "COMPLETED" -> getColor(R.color.status_success)
        "STOPPED" -> getColor(R.color.text_secondary)
        "FAILED" -> getColor(R.color.status_error)
        else -> getColor(R.color.text_secondary)
    }

    private fun confirmClearHistory() {
        val sessions = runCatching { store.list() }.getOrDefault(emptyList())
        if (sessions.isEmpty()) return
        val dialog = AlertDialog.Builder(this)
            .setTitle("清空全部历史")
            .setMessage(
                buildString {
                    append("将删除 ${sessions.size} 个本地会话及其事件记录。\n")
                    append("此操作无法撤销，确认继续吗？")
                },
            )
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.clear_all) { _, _ ->
                store.clear()
                SessionEventStore.clearAll(this)
                renderHistory()
                Toast.makeText(this, "已清空全部历史", Toast.LENGTH_SHORT).show()
            }
            .show()
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(getColor(R.color.status_error))
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setTextColor(getColor(R.color.text_secondary))
    }

    private fun resumeSession(session: Session) {
        ContextCompat.startForegroundService(
            this,
            Intent(this, TaskForegroundService::class.java).apply {
                action = TaskForegroundService.ACTION_RESUME
                putExtra(TaskForegroundService.EXTRA_TASK_ID, session.id)
                putExtra(TaskForegroundService.EXTRA_MODE, AgentMode.ACT.wireValue)
            },
        )
        Toast.makeText(this, "正在恢复会话", Toast.LENGTH_SHORT).show()
    }

    private fun showForkDialog(session: Session, maxSequence: Long) {
        val sequenceInput = EditText(this).apply {
            hint = "事件序号，例如 12"
            inputType = InputType.TYPE_CLASS_NUMBER
            contentDescription = "分支起点事件序号"
            setText(maxSequence.toString())
            setSelection(text.length)
            val horizontal = dp(20)
            setPadding(horizontal, dp(8), horizontal, dp(8))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("从指定事件创建分支")
            .setMessage("选择 ${session.prompt.ifBlank { "此会话" }} 中的事件序号。新分支会保留该事件之前的上下文。")
            .setView(sequenceInput)
            .setNegativeButton("取消", null)
            .setPositiveButton("创建", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val sequence = sequenceInput.text.toString().toLongOrNull()
                if (sequence == null || sequence !in 1L..maxSequence) {
                    sequenceInput.error = "请输入 1 到 $maxSequence 之间的事件序号"
                    return@setOnClickListener
                }
                startFork(session, sequence)
                dialog.dismiss()
            }
        }
        dialog.show()
    }

    private fun startFork(session: Session, sourceSequence: Long) {
        ContextCompat.startForegroundService(
            this,
            Intent(this, TaskForegroundService::class.java).apply {
                action = TaskForegroundService.ACTION_FORK_TASK
                putExtra(TaskForegroundService.EXTRA_TASK_ID, "fork-${System.currentTimeMillis()}")
                putExtra(TaskForegroundService.EXTRA_MODE, AgentMode.ACT.wireValue)
                putExtra(TaskForegroundService.EXTRA_SOURCE_SESSION_ID, session.id)
                putExtra(TaskForegroundService.EXTRA_SOURCE_SEQUENCE, sourceSequence)
            },
        )
        Toast.makeText(this, "正在创建会话分支", Toast.LENGTH_SHORT).show()
    }

    private fun actionLayoutParams(startMargin: Int = 0): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(0, dp(48), 1f).apply { marginStart = startMargin }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
