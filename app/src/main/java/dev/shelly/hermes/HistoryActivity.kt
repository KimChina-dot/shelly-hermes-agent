package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.DateFormat
import java.util.Date

/** A local, read-only task timeline. Session contents never leave app-private storage. */
class HistoryActivity : Activity() {
    private lateinit var store: SessionStore
    private lateinit var emptyState: TextView
    private lateinit var historyList: LinearLayout
    private lateinit var historyScroll: ScrollView
    private lateinit var clearButton: Button

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_history)
        store = FileSessionStore(this)
        emptyState = findViewById(R.id.historyEmptyState)
        historyList = findViewById(R.id.historyList)
        historyScroll = findViewById(R.id.historyScroll)
        clearButton = findViewById(R.id.clearHistoryButton)
        clearButton.setOnClickListener {
            store.clear()
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
        sessions.forEach { historyList.addView(createSessionCard(it)) }
    }

    private fun createSessionCard(session: Session): TextView = TextView(this).apply {
        setTextAppearance(R.style.TextAppearance_Luma_Body)
        setBackgroundColor(getColor(R.color.surface_glass))
        setPadding(dp(16), dp(14), dp(16), dp(14))
        text = buildString {
            append(session.prompt.ifBlank { "未命名任务" })
            append("\n")
            append(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(session.updatedAt)))
            if (session.status.isNotBlank()) append("\n状态：${session.status}")
            if (session.summary.isNotBlank()) append("\n结果：${session.summary}")
        }
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(10) }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
