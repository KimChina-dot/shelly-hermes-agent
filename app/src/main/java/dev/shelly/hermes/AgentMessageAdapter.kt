package dev.shelly.hermes

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

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
) : RecyclerView.Adapter<AgentMessageAdapter.MessageViewHolder>() {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): MessageViewHolder {
        val row = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_chat_message, parent, false) as LinearLayout
        return MessageViewHolder(row)
    }

    override fun getItemCount(): Int = messages.size

    override fun onBindViewHolder(holder: MessageViewHolder, position: Int) {
        holder.bind(messages[position])
    }

    inner class MessageViewHolder(private val row: LinearLayout) : RecyclerView.ViewHolder(row) {
        private val label = row.getChildAt(0) as TextView
        private val content = row.getChildAt(1) as TextView

        fun bind(message: UiMessage) {
            label.text = when (message.role) {
                UiMessageRole.USER -> "YOU"
                UiMessageRole.ASSISTANT -> "LUMA"
                UiMessageRole.STATUS -> "STATUS"
                UiMessageRole.TOOL -> message.title ?: "TOOL"
            }
            label.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            label.textSize = 11f
            label.setTextColor(context.getColor(R.color.text_tertiary))
            content.text = if (message.streaming) "${message.text}▍" else message.text
            content.textSize = 15f
            content.setTextIsSelectable(true)
            content.layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
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
            content.setTextColor(
                context.getColor(
                    if (message.role == UiMessageRole.STATUS) {
                        R.color.text_secondary
                    } else {
                        R.color.text_primary
                    },
                ),
            )
        }
    }

    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()
}
