package dev.shelly.hermes

import dev.shelly.hermes.core.CheckpointRequirement
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolPlugin
import dev.shelly.hermes.core.ToolPluginManifest
import dev.shelly.hermes.core.ToolPluginRuntime
import dev.shelly.hermes.core.ToolRisk
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Model-visible Android workspace tools and their reliability/security policy. */
object AndroidWorkspaceToolPlugins {
    private const val MAX_FILE_CHARS = 1_000_000

    val manifests: List<ToolPluginManifest> = listOf(
        manifest("read_file", "workspace.file.read", ToolRisk.LOW, false, 10_000, MAX_FILE_CHARS + 128),
        manifest("exists", "workspace.path.inspect", ToolRisk.LOW, false, 5_000, 256),
        manifest("list_files", "workspace.tree.list", ToolRisk.LOW, false, 20_000, 250_000),
        manifest("search_files", "workspace.text.search", ToolRisk.LOW, false, 30_000, 250_000),
        manifest("apply_patch", "workspace.file.patch", ToolRisk.MEDIUM, true, 20_000, 512, writes = true),
        manifest("create_file", "workspace.file.create", ToolRisk.HIGH, true, 20_000, 256, writes = true),
        manifest("overwrite_file", "workspace.file.overwrite", ToolRisk.HIGH, true, 20_000, 256, writes = true),
        manifest("append_file", "workspace.file.append", ToolRisk.HIGH, true, 20_000, 256, writes = true),
    )

    fun registerAll(runtime: ToolPluginRuntime, files: SafWorkspaceFileExecutor) {
        val handlers = mapOf<String, suspend (ToolCall) -> String>(
            "read_file" to { call ->
                val arguments = call.arguments()
                val content = files.readText(arguments.requiredString("path"))
                JSONObject()
                    .put("exists", content != null)
                    .put("content", content?.take(MAX_FILE_CHARS) ?: JSONObject.NULL)
                    .put("truncated", content != null && content.length > MAX_FILE_CHARS)
                    .toString()
            },
            "exists" to { call ->
                JSONObject().put("exists", files.exists(call.arguments().requiredString("path"))).toString()
            },
            "list_files" to { call ->
                val arguments = call.arguments()
                val result = files.listFiles(
                    arguments.optionalPath(),
                    arguments.boundedLimit(
                        default = SafWorkspaceFileExecutor.DEFAULT_LIST_LIMIT,
                        maximum = SafWorkspaceFileExecutor.MAX_LIST_LIMIT,
                    ),
                )
                JSONObject()
                    .put("entries", JSONArray(result.entries.map { entry ->
                        JSONObject()
                            .put("path", entry.path)
                            .put("type", if (entry.isDirectory) "directory" else "file")
                            .put("size", entry.size ?: JSONObject.NULL)
                    }))
                    .put("truncated", result.truncated)
                    .toString()
            },
            "search_files" to { call ->
                val arguments = call.arguments()
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
            },
            "apply_patch" to { call ->
                val arguments = call.arguments()
                val result = files.applyPatch(
                    arguments.requiredString("path"),
                    arguments.requiredString("patch"),
                )
                JSONObject()
                    .put("ok", true)
                    .put("hunks_applied", result.hunksApplied)
                    .put("characters_written", result.charactersWritten)
                    .toString()
            },
            "create_file" to writeHandler { files.createText(it.first, it.second) },
            "overwrite_file" to writeHandler { files.overwriteText(it.first, it.second) },
            "append_file" to writeHandler { files.appendText(it.first, it.second) },
        )

        manifests.forEach { pluginManifest ->
            runtime.register(plugin(pluginManifest, handlers.getValue(pluginManifest.name)))
        }
    }

    internal fun plugin(
        manifest: ToolPluginManifest,
        handler: suspend (ToolCall) -> String,
    ): ToolPlugin = object : ToolPlugin {
        override val manifest = manifest

        override suspend fun execute(call: ToolCall): String {
            require(call.name == manifest.name) {
                "Tool plugin ${manifest.name} cannot execute ${call.name}"
            }
            return handler(call)
        }
    }

    private fun manifest(
        name: String,
        capability: String,
        risk: ToolRisk,
        requiresApproval: Boolean,
        timeoutMillis: Long,
        maxOutputChars: Int,
        writes: Boolean = false,
    ) = ToolPluginManifest(
        name = name,
        capability = capability,
        risk = risk,
        requiresApproval = requiresApproval,
        timeoutMillis = timeoutMillis,
        maxOutputChars = maxOutputChars,
        checkpointRequirement = if (writes) CheckpointRequirement.REQUIRED else CheckpointRequirement.NONE,
        failureThreshold = if (writes) 2 else 3,
        circuitResetMillis = 30_000,
    )

    private fun writeHandler(action: (Pair<String, String>) -> Unit): suspend (ToolCall) -> String = { call ->
        val arguments = call.arguments()
        action(arguments.requiredString("path") to arguments.requiredContent())
        JSONObject().put("ok", true).toString()
    }

    private fun ToolCall.arguments(): JSONObject = try {
        JSONObject(argumentsJson.ifBlank { "{}" })
    } catch (error: JSONException) {
        throw IllegalArgumentException("Tool arguments must be a JSON object", error)
    }

    private fun JSONObject.requiredString(name: String): String {
        if (!has(name) || isNull(name)) throw IllegalArgumentException("Missing tool argument: $name")
        return getString(name)
    }

    private fun JSONObject.requiredContent(): String = requiredString("content").also {
        require(it.length <= MAX_FILE_CHARS) { "Tool content exceeds the write limit" }
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
}
