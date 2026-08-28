package dev.shelly.hermes

import android.content.Context
import android.graphics.Typeface
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
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
    val toolArgs: String? = null,
    val toolResult: String? = null,
)

class AgentMessageAdapter(
    private val context: Context,
    private val messages: List<UiMessage>,
) : RecyclerView.Adapter<AgentMessageAdapter.MessageViewHolder>() {

    private val expandedToolCallIds = mutableSetOf<String>()

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
        private val container = row
        private val label = row.findViewById<TextView>(R.id.roleLabel)
        private val stateChip = row.findViewById<TextView>(R.id.stateChip)
        private val expandHint = row.findViewById<TextView>(R.id.expandHint)
        private val content = row.findViewById<TextView>(R.id.content)
        private val details = row.findViewById<TextView>(R.id.details)

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
            stateChip.text = visibleStateLabel(message.toolState)
            stateChip.visibility = if (stateChip.text.isNullOrBlank()) {
                android.view.View.GONE
            } else {
                stateChip.setBackgroundResource(stateBackground(message.toolState))
                stateChip.setTextColor(stateColor(message.toolState))
                android.view.View.VISIBLE
            }
            content.text = if (message.streaming) "${message.text}▍" else message.text
            content.textSize = 15f
            content.setTextIsSelectable(true)
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
            bindExpandable(message)
        }

        private fun bindExpandable(message: UiMessage) {
            val position = bindingAdapterPosition
            val hasDetails = message.role == UiMessageRole.TOOL &&
                (!message.toolArgs.isNullOrBlank() || !message.toolResult.isNullOrBlank())
            if (!hasDetails) {
                expandHint.visibility = View.GONE
                details.visibility = View.GONE
                expandHint.setOnClickListener(null)
                return
            }
            val key = message.toolCallId.orEmpty()
            val expanded = expandedToolCallIds.contains(key)
            expandHint.visibility = View.VISIBLE
            expandHint.text = context.getString(
                if (expanded) R.string.collapse_details else R.string.expand_details,
            )
            expandHint.setOnClickListener {
                if (!expandedToolCallIds.add(key)) expandedToolCallIds.remove(key)
                if (position >= 0) notifyItemChanged(position)
            }
            details.visibility = if (expanded) View.VISIBLE else View.GONE
            if (expanded) {
                details.text = buildString {
                    if (!message.toolArgs.isNullOrBlank()) {
                        append("输入\n")
                        append(message.toolArgs)
                    }
                    if (!message.toolResult.isNullOrBlank()) {
                        if (isNotEmpty()) append("\n\n")
                        append("输出\n")
                        append(message.toolResult)
                    }
                }
            }
        }

        private fun visibleStateLabel(state: String?): String? = when (state) {
            null, "" -> null
            "RUNNING" -> "执行中"
            "FINISHED" -> "已完成"
            "FAILED" -> "失败"
            "WAITING_FOR_APPROVAL" -> "等待审批"
            else -> state
        }

        private fun stateBackground(state: String?): Int = when (state) {
            "RUNNING" -> R.drawable.bg_chip_running
            "FINISHED" -> R.drawable.bg_chip_success
            "FAILED" -> R.drawable.bg_chip_error
            "WAITING_FOR_APPROVAL" -> R.drawable.bg_chip_warning
            else -> R.drawable.bg_chip
        }

        private fun stateColor(state: String?): Int = when (state) {
            "RUNNING" -> context.getColor(R.color.accent_primary)
            "FINISHED" -> context.getColor(R.color.status_success)
            "FAILED" -> context.getColor(R.color.status_error)
            "WAITING_FOR_APPROVAL" -> context.getColor(R.color.status_warning)
            else -> context.getColor(R.color.text_secondary)
        }
    }

    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()
}
