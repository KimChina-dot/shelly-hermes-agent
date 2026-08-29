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
import org.json.JSONArray
import org.json.JSONObject

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
    private val onRegenerate: (() -> Unit)? = null,
    private val onOpenArtifact: ((UiMessage) -> Unit)? = null,
    private val onShareArtifact: ((UiMessage) -> Unit)? = null,
    private val onDownloadArtifact: ((UiMessage) -> Unit)? = null,
) : RecyclerView.Adapter<AgentMessageAdapter.MessageViewHolder>() {

    private val expandedToolCallIds = mutableSetOf<String>()

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): MessageViewHolder {
        val row = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_chat_message, parent, false) as LinearLayout
        return MessageViewHolder(row)
    }

    override fun getItemCount(): Int = messages.size

    override fun onBindViewHolder(holder: MessageViewHolder, position: Int) {
        holder.bind(messages[position], position)
    }

    inner class MessageViewHolder(private val row: LinearLayout) : RecyclerView.ViewHolder(row) {
        private val container = row
        private val label = row.findViewById<TextView>(R.id.roleLabel)
        private val typeBadge = row.findViewById<TextView>(R.id.typeBadge)
        private val stateChip = row.findViewById<TextView>(R.id.stateChip)
        private val expandHint = row.findViewById<TextView>(R.id.expandHint)
        private val retryHint = row.findViewById<TextView>(R.id.retryHint)
        private val regenerateHint = row.findViewById<TextView>(R.id.regenerateHint)
        private val copyHint = row.findViewById<TextView>(R.id.copyHint)
        private val content = row.findViewById<TextView>(R.id.content)
        private val failureSuggestion = row.findViewById<TextView>(R.id.failureSuggestion)
        private val details = row.findViewById<TextView>(R.id.details)
        private val artifactImage = row.findViewById<ImageView>(R.id.artifactImage)
        private val artifactActions = row.findViewById<LinearLayout>(R.id.artifactActions)
        private val openArtifactHint = row.findViewById<TextView>(R.id.openArtifactHint)
        private val shareArtifactHint = row.findViewById<TextView>(R.id.shareArtifactHint)
        private val saveArtifactHint = row.findViewById<TextView>(R.id.saveArtifactHint)

        fun bind(message: UiMessage, position: Int) {
            label.text = when (message.role) {
                UiMessageRole.USER -> "YOU"
                UiMessageRole.ASSISTANT -> "LUMA"
                UiMessageRole.STATUS -> "STATUS"
                UiMessageRole.TOOL -> message.title ?: "TOOL"
                UiMessageRole.ARTIFACT -> message.title ?: "ARTIFACT"
            }
            label.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            label.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, context.resources.getDimension(R.dimen.type_micro))
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
            val visibleContent = when {
                message.streaming -> "${message.text}▍"
                message.role == UiMessageRole.TOOL -> parameterSummary(message)
                else -> message.text
            }
            content.text = visibleContent
            content.contentDescription = if (message.role == UiMessageRole.TOOL) {
                "工具参数摘要 $visibleContent"
            } else {
                null
            }
            content.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, context.resources.getDimension(R.dimen.type_body))
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
            bindFailureSuggestion(message)
            bindExpandable(message)
            bindRetry(message)
            bindRegenerate(message, position)
            bindCopy(message)
            bindArtifactActions(message)
            bindArtifactImage(message)
        }

        private fun bindFailureSuggestion(message: UiMessage) {
            val suggestion = if (message.role == UiMessageRole.TOOL && message.toolState == "FAILED") {
                suggestionFor(message.toolResult.orEmpty())
            } else {
                ""
            }
            failureSuggestion.visibility = if (suggestion.isBlank()) View.GONE else View.VISIBLE
            failureSuggestion.text = suggestion
            failureSuggestion.contentDescription = if (suggestion.isBlank()) {
                null
            } else {
                "失败建议：$suggestion"
            }
        }

        private fun suggestionFor(error: String): String {
            val value = error.lowercase()
            return when {
                "approval" in value || "permission" in value || "denied" in value ->
                    "需要审批或目录授权；请确认授权范围后重试。"
                "network" in value || "unreachable" in value || "timeout" in value || "connection" in value ->
                    "网络或服务暂时不可用；请检查网络后稍后重试。"
                "http 401" in value || "http 403" in value || "unauthorized" in value || "forbidden" in value ->
                    "访问被拒绝；请检查模型地址、密钥或服务权限。"
                "http 429" in value || "rate limit" in value || "quota" in value ->
                    "请求被限流或额度不足；请等待后重试。"
                "http 404" in value || "model" in value ->
                    "模型或接口地址可能不正确；请检查模型配置。"
                "no such file" in value || "file not found" in value || "path" in value ->
                    "文件不存在或不在授权项目内；请确认文件路径。"
                "patch" in value || "conflict" in value || "stale" in value ->
                    "目标内容可能已变化；请重新读取文件后再应用补丁。"
                "invalid" in value || "required" in value || "schema" in value || "argument" in value ->
                    "工具输入不符合要求；请调整参数后重试。"
                "command" in value || "process" in value || "exit code" in value ->
                    "命令执行失败；请检查命令、工作目录和项目环境。"
                error.isNotBlank() ->
                    "查看展开输出中的完整错误；如果问题仍在，可稍后重试。"
                else ->
                    "工具失败且未返回详情；请稍后重试或更换任务描述。"
            }
        }

        private fun parameterSummary(message: UiMessage): String {
            val arguments = runCatching {
                JSONObject(message.toolArgs.ifBlank { "{}" })
            }.getOrNull() ?: return message.text.ifBlank { "无参数" }
            val summary = when (message.title?.lowercase()) {
                "read_file" -> "读取 ${arguments.optString("path")}"
                "exists" -> "检查 ${arguments.optString("path")}"
                "list_files" -> "列出 ${arguments.optString("path").ifBlank { "项目根目录" }}"
                "search_files" -> buildString {
                    append("搜索 ${arguments.optString("query")}")
                    val path = arguments.optString("path")
                    if (path.isNotBlank()) append("（$path）")
                }
                "repo_map" -> "生成仓库地图 ${arguments.optString("path").ifBlank { "项目根目录" }}"
                "batch_read" -> {
                    val paths = arguments.optJSONArray("paths")
                    if (paths != null) "批量读取 ${paths.length()} 个文件" else "批量读取文件"
                }
                "create_file" -> "创建 ${arguments.optString("path")}"
                "overwrite_file" -> "覆盖 ${arguments.optString("path")}"
                "append_file" -> "追加 ${arguments.optString("path")}"
                "apply_patch_hunk" -> "应用补丁 ${arguments.optString("path")}"
                "run_process", "start_shell_command" -> "运行 ${arguments.optString("command")}"
                else -> arguments.keys()
                    .asSequence()
                    .mapNotNull { key ->
                        arguments.opt(key)?.takeIf {
                            it != JSONObject.NULL && it.toString().isNotBlank()
                        }?.let { key to it }
                    }
                    .joinToString(" · ") { "${it.first} ${formatSummaryValue(it.second)}" }
                    .takeIf { it.isNotBlank() }
                    ?: "无参数"
            }
            return clipSummary(summary)
        }

        private fun formatSummaryValue(value: Any): String {
            return when (value) {
                is JSONObject -> "${value.length()} 项"
                is JSONArray -> "${value.length()} 项"
                else -> {
                    val text = value.toString()
                    if (value is String && text.length > 80) "${text.length} 字符" else text
                }
            }
        }

        private fun clipSummary(value: String): String {
            val text = value.replace(Regex("\\s+"), " ").trim()
            return if (text.length <= 120) text else "${text.take(117)}..."
        }

        private fun bindArtifactActions(message: UiMessage) {
            val isArtifact = message.role == UiMessageRole.ARTIFACT &&
                !message.artifactPath.isNullOrBlank()
            artifactActions.visibility = if (isArtifact) View.VISIBLE else View.GONE
            if (!isArtifact) {
                openArtifactHint.setOnClickListener(null)
                shareArtifactHint.setOnClickListener(null)
                saveArtifactHint.setOnClickListener(null)
                openArtifactHint.visibility = View.GONE
                shareArtifactHint.visibility = View.GONE
                saveArtifactHint.visibility = View.GONE
                return
            }
            openArtifactHint.visibility = View.VISIBLE
            shareArtifactHint.visibility = View.VISIBLE
            saveArtifactHint.visibility = View.VISIBLE
            openArtifactHint.contentDescription = "打开产物 ${message.title}"
            shareArtifactHint.contentDescription = "分享产物 ${message.title}"
            saveArtifactHint.contentDescription = "保存产物 ${message.title} 到下载目录"
            openArtifactHint.isFocusable = true
            shareArtifactHint.isFocusable = true
            saveArtifactHint.isFocusable = true
            openArtifactHint.setOnClickListener {
                onOpenArtifact?.invoke(message)
            }
            shareArtifactHint.setOnClickListener {
                onShareArtifact?.invoke(message)
            }
            saveArtifactHint.setOnClickListener {
                onDownloadArtifact?.invoke(message)
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
            retryHint.contentDescription = "重试失败工具 ${message.title} 所属的上次任务"
            retryHint.setOnClickListener(if (canRetry) { View.OnClickListener { onRetry?.invoke() } } else null)
            retryHint.isFocusable = canRetry
        }

        private fun bindRegenerate(message: UiMessage, position: Int) {
            val latestAssistant = messages.indexOfLast { candidate ->
                candidate.role == UiMessageRole.ASSISTANT &&
                    candidate.text.isNotBlank() &&
                    !candidate.streaming
            }
            val canRegenerate = onRegenerate != null &&
                position == latestAssistant &&
                message.role == UiMessageRole.ASSISTANT &&
                message.text.isNotBlank() &&
                !message.streaming
            regenerateHint.visibility = if (canRegenerate) View.VISIBLE else View.GONE
            regenerateHint.contentDescription = "重新生成这条回复"
            regenerateHint.setOnClickListener(if (canRegenerate) {
                View.OnClickListener { onRegenerate?.invoke() }
            } else null)
            regenerateHint.isFocusable = canRegenerate
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
            val detailTarget = when (message.role) {
                UiMessageRole.ARTIFACT -> "产物 ${message.title}"
                else -> "工具 ${message.title}"
            }
            expandHint.contentDescription =
                "${if (expanded) "收起" else "查看"} $detailTarget 详情"
            expandHint.isFocusable = true
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
