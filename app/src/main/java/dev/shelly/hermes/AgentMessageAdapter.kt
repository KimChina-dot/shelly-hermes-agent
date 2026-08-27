package dev.shelly.hermes

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.LinearLayout
import android.widget.TextView

enum class UiMessageRole { USER, ASSISTANT, STATUS, TOOL }

data class UiMessage(
    val role: UiMessageRole,
    val text: String,
    val title: String? = null,
    val toolCallId: String? = null,
    val toolState: String? = null,
    val streaming: Boolean = false,
)

class AgentMessageAdapter(
    private val context: Context,
    private val messages: List<UiMessage>,
) : BaseAdapter() {
    override fun getCount(): Int = messages.size
    override fun getItem(position: Int): UiMessage = messages[position]
    override fun getItemId(position: Int): Long = position.toLong()

    override fun getView(position: Int, recycled: View?, parent: ViewGroup?): View {
        val row = (recycled as? LinearLayout) ?: createRow()
        val message = getItem(position)
        val label = row.getChildAt(0) as TextView
        val content = row.getChildAt(1) as TextView
        label.text = when (message.role) {
            UiMessageRole.USER -> "YOU"
            UiMessageRole.ASSISTANT -> "LUMA"
            UiMessageRole.STATUS -> "STATUS"
            UiMessageRole.TOOL -> message.title ?: "TOOL"
        }
        content.text = if (message.streaming) "${message.text}▍" else message.text
        row.gravity = if (message.role == UiMessageRole.USER) Gravity.END else Gravity.START
        content.setBackgroundResource(
            when (message.role) {
                UiMessageRole.USER -> R.drawable.bg_user_message
                UiMessageRole.ASSISTANT -> R.drawable.bg_glass_card
                UiMessageRole.TOOL -> R.drawable.bg_surface_card
                UiMessageRole.STATUS -> android.R.color.transparent
            },
        )
        content.setPadding(
            dp(if (message.role == UiMessageRole.USER) 14 else 12),
            dp(10),
            dp(if (message.role == UiMessageRole.USER) 14 else 12),
            dp(10),
        )
        content.setTextColor(context.getColor(
            if (message.role == UiMessageRole.STATUS) R.color.text_secondary else R.color.text_primary,
        ))
        return row
    }

    private fun createRow() = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(10), dp(16), dp(10))
        addView(TextView(context).apply {
            textSize = 11f
            setTextColor(context.getColor(R.color.text_tertiary))
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        })
        addView(TextView(context).apply {
            textSize = 15f
            setTextIsSelectable(true)
            maxWidth = dp(720)
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        })
    }

    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()
}
