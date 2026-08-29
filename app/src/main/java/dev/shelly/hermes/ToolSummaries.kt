package dev.shelly.hermes

import org.json.JSONArray
import org.json.JSONObject

/** Shared summaries so approval and message cards use the same human-readable language. */
internal object ToolSummaries {
    fun parameterSummary(
        toolName: String?,
        argumentsJson: String?,
        fallback: String = "无参数",
    ): String {
        val arguments = runCatching {
            JSONObject(argumentsJson.orEmpty().ifBlank { "{}" })
        }.getOrNull() ?: return fallback
        val summary = when (toolName?.lowercase()) {
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
                .joinToString(" · ") { "${it.first} ${formatValue(it.second)}" }
                .takeIf { it.isNotBlank() }
                ?: fallback
        }
        return clip(summary)
    }

    private fun formatValue(value: Any): String = when (value) {
        is JSONObject -> "${value.length()} 项"
        is JSONArray -> "${value.length()} 项"
        else -> {
            val text = value.toString()
            if (value is String && text.length > 80) "${text.length} 字符" else text
        }
    }

    private fun clip(value: String): String {
        val text = value.replace(Regex("\\s+"), " ").trim()
        return if (text.length <= 120) text else "${text.take(117)}..."
    }
}
