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
        historySummary = findViewById(R.id.historySummary)
        clearButton.setOnClickListener {
            store.clear()
            SessionEventStore.clearAll(this)
            renderHistory()
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
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(getColor(R.color.surface_glass))
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
            setTextAppearance(R.style.TextAppearance_Luma_Caption)
            setPadding(0, dp(4), 0, 0)
            text = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                .format(Date(session.updatedAt))
        })
        addView(TextView(context).apply {
            setTextAppearance(R.style.TextAppearance_Luma_Body)
            setPadding(0, dp(10), 0, 0)
            text = buildString {
                append("状态：")
                append(session.status.ifBlank { "历史记录" })
                append("\n事件摘要：")
                append(session.summary.ifBlank { "旧版会话暂无事件摘要，可继续恢复此任务。" })
                if (maxSequence > 0L) append("\n事件：$maxSequence 条")
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
                    "$role：${message.content}"
                }
            }
        }
        addView(Button(context).apply {
            text = "查看完整会话"
            isAllCaps = false
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
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, 0)
            addView(Button(context).apply {
                text = "恢复"
                isAllCaps = false
                contentDescription = "恢复会话 ${session.prompt.ifBlank { session.id }}"
                setOnClickListener { resumeSession(session) }
            }, actionLayoutParams())
            addView(Button(context).apply {
                text = "从事件分叉"
                isAllCaps = false
                isEnabled = maxSequence > 0L
                contentDescription = "从指定事件创建会话分支"
                setOnClickListener { showForkDialog(session, maxSequence) }
            }, actionLayoutParams(startMargin = dp(8)))
        })
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
