package dev.shelly.hermes

import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolExecutor
import org.json.JSONException
import org.json.JSONObject

/** Strict tool whitelist over the SAF workspace adapter. */
class SafWorkspaceToolExecutor(
    private val files: SafWorkspaceFileExecutor,
) : ToolExecutor {
    override suspend fun execute(call: ToolCall): String {
        val arguments = try {
            JSONObject(call.argumentsJson.ifBlank { "{}" })
        } catch (error: JSONException) {
            throw IllegalArgumentException("Tool arguments must be a JSON object", error)
        }
        val path = arguments.requiredString("path")
        return when (call.name) {
            "read_file" -> {
                val content = files.readText(path)
                JSONObject()
                    .put("exists", content != null)
                    .put("content", content?.take(MAX_READ_CHARS) ?: JSONObject.NULL)
                    .put("truncated", content != null && content.length > MAX_READ_CHARS)
                    .toString()
            }
            "exists" -> JSONObject().put("exists", files.exists(path)).toString()
            "create_file" -> writeResult { files.createText(path, arguments.requiredContent()) }
            "overwrite_file" -> writeResult { files.overwriteText(path, arguments.requiredContent()) }
            "append_file" -> writeResult { files.appendText(path, arguments.requiredContent()) }
            else -> throw IllegalArgumentException("Unsupported workspace tool: ${call.name}")
        }
    }

    private fun JSONObject.requiredString(name: String): String {
        if (!has(name) || isNull(name)) throw IllegalArgumentException("Missing tool argument: $name")
        return getString(name)
    }

    private fun JSONObject.requiredContent(): String = requiredString("content").also {
        require(it.length <= MAX_WRITE_CHARS) { "Tool content exceeds the write limit" }
    }

    private fun writeResult(action: () -> Unit): String {
        action()
        return JSONObject().put("ok", true).toString()
    }

    companion object {
        private const val MAX_READ_CHARS = 1_000_000
        private const val MAX_WRITE_CHARS = 1_000_000
    }
}
