package dev.shelly.hermes

import android.content.Context
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.recyclerview.widget.RecyclerView
import java.text.DateFormat
import java.util.Date
import java.util.Locale

enum class UiMessageRole { USER, ASSISTANT, STATUS, TOOL, ARTIFACT }

data class UiMessage(
    val role: UiMessageRole,
    val text: String,
    val title: String? = null,
    val toolCallId: String? = null,
    val toolState: String? = null,
    val toolStartedAtMillis: Long? = null,
    val toolDurationMillis: Long? = null,
    val streaming: Boolean = false,
    val toolArgs: String? = null,
    val toolResult: String? = null,
    val artifactPath: String? = null,
    val artifactType: String? = null,
    val artifactImageBytes: ByteArray? = null,
)

class AgentMessageAdapter(
    private val context: Context,
    private val messages: List<UiMessage>,
    private val onRetry: (() -> Unit)? = null,
    private val onOpenArtifact: ((UiMessage) -> Unit)? = null,
    private val onShareArtifact: ((UiMessage) -> Unit)? = null,
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
        private val typeBadge = row.findViewById<TextView>(R.id.typeBadge)
        private val stateChip = row.findViewById<TextView>(R.id.stateChip)
        private val expandHint = row.findViewById<TextView>(R.id.expandHint)
        private val retryHint = row.findViewById<TextView>(R.id.retryHint)
        private val copyHint = row.findViewById<TextView>(R.id.copyHint)
        private val content = row.findViewById<TextView>(R.id.content)
        private val details = row.findViewById<TextView>(R.id.details)
        private val artifactImage = row.findViewById<ImageView>(R.id.artifactImage)
        private val artifactActions = row.findViewById<LinearLayout>(R.id.artifactActions)
        private val openArtifactHint = row.findViewById<TextView>(R.id.openArtifactHint)
        private val shareArtifactHint = row.findViewById<TextView>(R.id.shareArtifactHint)

        fun bind(message: UiMessage) {
            label.text = when (message.role) {
                UiMessageRole.USER -> "YOU"
                UiMessageRole.ASSISTANT -> "LUMA"
                UiMessageRole.STATUS -> "STATUS"
                UiMessageRole.TOOL -> message.title ?: "TOOL"
                UiMessageRole.ARTIFACT -> message.title ?: "ARTIFACT"
            }
            label.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            label.textSize = 11f
            label.setTextColor(context.getColor(R.color.text_tertiary))
            if (message.role == UiMessageRole.ARTIFACT) {
                typeBadge.text = message.artifactType?.uppercase() ?: "FILE"
                typeBadge.visibility = View.VISIBLE
                typeBadge.contentDescription = "产物类型 ${typeBadge.text}"
            } else {
                typeBadge.visibility = View.GONE
            }
            label.contentDescription = if (message.role == UiMessageRole.ARTIFACT) {
                "产物 ${message.title}"
            } else {
                label.text
            }
            stateChip.text = visibleStateLabel(
                message.toolState,
                message.toolDurationMillis,
                message.toolStartedAtMillis,
            )
            stateChip.visibility = if (stateChip.text.isNullOrBlank()) {
                android.view.View.GONE
            } else {
                stateChip.setBackgroundResource(stateBackground(message.toolState))
                stateChip.setTextColor(stateColor(message.toolState))
                android.view.View.VISIBLE
            }
            stateChip.contentDescription = if (message.role == UiMessageRole.TOOL) {
                buildString {
                    append("工具状态 ${stateChip.text}")
                    formatStartedTime(message.toolStartedAtMillis)?.let { append("，开始 $it") }
                    formatDuration(message.toolDurationMillis)?.let { append("，耗时 $it") }
                }
            } else {
                stateChip.text
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
                    UiMessageRole.ARTIFACT -> R.drawable.bg_surface_card
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
            bindRetry(message)
            bindCopy(message)
            bindArtifactActions(message)
            bindArtifactImage(message)
        }

        private fun bindArtifactActions(message: UiMessage) {
            val isArtifact = message.role == UiMessageRole.ARTIFACT &&
                !message.artifactPath.isNullOrBlank()
            artifactActions.visibility = if (isArtifact) View.VISIBLE else View.GONE
            if (!isArtifact) {
                openArtifactHint.setOnClickListener(null)
                shareArtifactHint.setOnClickListener(null)
                openArtifactHint.visibility = View.GONE
                shareArtifactHint.visibility = View.GONE
                return
            }
            openArtifactHint.visibility = View.VISIBLE
            shareArtifactHint.visibility = View.VISIBLE
            openArtifactHint.contentDescription = "打开产物 ${message.title}"
            shareArtifactHint.contentDescription = "分享产物 ${message.title}"
            openArtifactHint.setOnClickListener {
                onOpenArtifact?.invoke(message)
            }
            shareArtifactHint.setOnClickListener {
                onShareArtifact?.invoke(message)
            }
        }

        private fun bindArtifactImage(message: UiMessage) {
            val bytes = message.artifactImageBytes
            if (message.role != UiMessageRole.ARTIFACT || bytes == null) {
                artifactImage.visibility = View.GONE
                artifactImage.setImageDrawable(null)
                return
            }
            val bitmap = decodeScaled(bytes, 1200)
            if (bitmap == null) {
                artifactImage.visibility = View.GONE
                return
            }
            artifactImage.setImageBitmap(bitmap)
            artifactImage.visibility = View.VISIBLE
            artifactImage.contentDescription = "产物图片 ${message.title}"
        }

        private fun decodeScaled(bytes: ByteArray, maxPixels: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxPixels || bounds.outHeight / (sample * 2) >= maxPixels) {
                sample *= 2
            }
            return BitmapFactory.decodeByteArray(
                bytes,
                0,
                bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        }

        private fun bindRetry(message: UiMessage) {
            val canRetry = message.role == UiMessageRole.TOOL &&
                message.toolState == "FAILED" &&
                onRetry != null
            retryHint.visibility = if (canRetry) View.VISIBLE else View.GONE
            retryHint.setOnClickListener(if (canRetry) { View.OnClickListener { onRetry?.invoke() } } else null)
        }

        private fun bindCopy(message: UiMessage) {
            val canCopy = message.role in setOf(UiMessageRole.USER, UiMessageRole.ASSISTANT) &&
                message.text.isNotBlank() &&
                !message.streaming
            copyHint.visibility = if (canCopy) View.VISIBLE else View.GONE
            copyHint.contentDescription = context.getString(R.string.copy_message_content)
            copyHint.setOnClickListener(if (canCopy) {
                View.OnClickListener {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(
                        android.content.ClipData.newPlainText(
                            context.getString(R.string.copy_message),
                            message.text,
                        ),
                    )
                    Toast.makeText(context, R.string.message_copied, Toast.LENGTH_SHORT).show()
                }
            } else null)
        }

        private fun bindExpandable(message: UiMessage) {
            val position = bindingAdapterPosition
            val hasDetails = (message.role == UiMessageRole.TOOL || message.role == UiMessageRole.ARTIFACT) &&
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
            expandHint.contentDescription = context.getString(
                if (expanded) R.string.collapse_details else R.string.expand_details,
            )
            expandHint.setOnClickListener {
                if (!expandedToolCallIds.add(key)) expandedToolCallIds.remove(key)
                if (position >= 0) notifyItemChanged(position)
            }
            details.visibility = if (expanded) View.VISIBLE else View.GONE
            if (expanded) {
                details.text = buildString {
                    if (message.role == UiMessageRole.ARTIFACT && !message.artifactPath.isNullOrBlank()) {
                        append("路径\n")
                        append(message.artifactPath)
                        append("\n\n")
                    }
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
                details.alpha = 0f
                details.translationY = dp(4).toFloat()
                details.animate()
                    .alpha(1f)
                    .translationY(0f)
                    .setDuration(180L)
                    .start()
            }
        }

        private fun visibleStateLabel(
            state: String?,
            durationMillis: Long?,
            startedAtMillis: Long?,
        ): String {
            val stateText = when (state) {
                null, "" -> null
                "PENDING" -> "等待执行"
                "RUNNING" -> "执行中"
                "FINISHED" -> "已完成"
                "FAILED" -> "失败"
                "CANCELLED" -> "已取消"
                "WAITING_FOR_APPROVAL" -> "等待审批"
                else -> state
            }
            val duration = formatDuration(durationMillis)
            val startedAt = formatStartedTime(startedAtMillis)
            return listOfNotNull(stateText, startedAt?.let { "开始 $it" }, duration)
                .joinToString(" · ")
        }

        private fun formatDuration(durationMillis: Long?): String? {
            val millis = durationMillis ?: return null
            if (millis < 0) return null
            return if (millis < 1_000) "${millis}ms" else "%.1fs".format(millis / 1_000.0)
        }

        private fun formatStartedTime(startedAtMillis: Long?): String? {
            val millis = startedAtMillis ?: return null
            if (millis <= 0) return null
            return DateFormat.getTimeInstance(DateFormat.SHORT, Locale.getDefault()).format(Date(millis))
        }

        private fun stateBackground(state: String?): Int = when (state) {
            "PENDING" -> R.drawable.bg_chip
            "RUNNING" -> R.drawable.bg_chip_running
            "FINISHED" -> R.drawable.bg_chip_success
            "FAILED" -> R.drawable.bg_chip_error
            "CANCELLED" -> R.drawable.bg_chip
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
