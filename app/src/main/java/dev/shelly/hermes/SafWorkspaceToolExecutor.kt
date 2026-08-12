package dev.shelly.hermes

import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolExecutor
import org.json.JSONArray
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
        return when (call.name) {
            "read_file" -> {
                val path = arguments.requiredString("path")
                val content = files.readText(path)
                JSONObject()
                    .put("exists", content != null)
                    .put("content", content?.take(MAX_READ_CHARS) ?: JSONObject.NULL)
                    .put("truncated", content != null && content.length > MAX_READ_CHARS)
                    .toString()
            }
            "exists" -> JSONObject().put("exists", files.exists(arguments.requiredString("path"))).toString()
            "list_files" -> {
                val result = files.listFiles(arguments.optionalPath(), arguments.boundedLimit(
                    default = SafWorkspaceFileExecutor.DEFAULT_LIST_LIMIT,
                    maximum = SafWorkspaceFileExecutor.MAX_LIST_LIMIT,
                ))
                JSONObject()
                    .put("entries", JSONArray(result.entries.map { entry ->
                        JSONObject()
                            .put("path", entry.path)
                            .put("type", if (entry.isDirectory) "directory" else "file")
                            .put("size", entry.size ?: JSONObject.NULL)
                    }))
                    .put("truncated", result.truncated)
                    .toString()
            }
            "search_files" -> {
                val result = files.searchFiles(
                    query = arguments.requiredString("query"),
                    path = arguments.optionalPath(),
                    maxResults = arguments.boundedLimit(
                        default = SafWorkspaceFileExecutor.DEFAULT_SEARCH_LIMIT,
                        maximum = SafWorkspaceFileExecutor.MAX_SEARCH_LIMIT,
                    ),
                )
                JSONObject()
                    .put("matches", JSONArray(result.matches.map { match ->
                        JSONObject()
                            .put("path", match.path)
                            .put("line", match.line)
                            .put("column", match.column)
                            .put("preview", match.preview)
                    }))
                    .put("truncated", result.truncated)
                    .toString()
            }
            "apply_patch" -> {
                val result = files.applyPatch(
                    arguments.requiredString("path"),
                    arguments.requiredString("patch"),
                )
                JSONObject()
                    .put("ok", true)
                    .put("hunks_applied", result.hunksApplied)
                    .put("characters_written", result.charactersWritten)
                    .toString()
            }
            "create_file" -> writeResult {
                files.createText(arguments.requiredString("path"), arguments.requiredContent())
            }
            "overwrite_file" -> writeResult {
                files.overwriteText(arguments.requiredString("path"), arguments.requiredContent())
            }
            "append_file" -> writeResult {
                files.appendText(arguments.requiredString("path"), arguments.requiredContent())
            }
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

    private fun JSONObject.optionalPath(): String? = optString("path")
        .takeIf { it.isNotBlank() }
        ?.let(LogicalPath::validate)

    private fun JSONObject.boundedLimit(default: Int, maximum: Int): Int {
        if (!has("max_results") || isNull("max_results")) return default
        val value = try {
            getInt("max_results")
        } catch (error: JSONException) {
            throw IllegalArgumentException("Tool argument max_results must be an integer", error)
        }
        require(value in 1..maximum) { "Tool argument max_results must be between 1 and $maximum" }
        return value
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
