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
        manifest("repo_map", "workspace.tree.map", ToolRisk.LOW, false, 20_000, 250_000),
        manifest("batch_read", "workspace.file.batch_read", ToolRisk.LOW, false, 30_000, MAX_FILE_CHARS * 4 + 1024),
        manifest("run_command", "workspace.shell.execute", ToolRisk.MEDIUM, true, 30_000, 64_000),
        manifest("rollback_file", "workspace.file.rollback", ToolRisk.MEDIUM, true, 20_000, 512, writes = true),
        manifest("apply_patch", "workspace.file.patch", ToolRisk.MEDIUM, true, 20_000, 512, writes = true),
        manifest("create_file", "workspace.file.create", ToolRisk.HIGH, true, 20_000, 256, writes = true),
        manifest("overwrite_file", "workspace.file.overwrite", ToolRisk.HIGH, true, 20_000, 256, writes = true),
        manifest("append_file", "workspace.file.append", ToolRisk.HIGH, true, 20_000, 256, writes = true),
    )

    fun registerAll(
        runtime: ToolPluginRuntime,
        files: SafWorkspaceFileExecutor,
        shell: ShellToolExecutor? = null,
        backups: WorkspaceBackupStore? = null,
    ) {
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
            "repo_map" to { call ->
                val arguments = call.arguments()
                val result = files.listFiles(
                    path = null,
                    maxResults = arguments.boundedLimit(
                        default = 100,
                        maximum = 500,
                    ),
                )
                val tree = StringBuilder()
                tree.appendLine("PROJECT STRUCTURE:")
                val filesByDir = result.entries.filter { !it.isDirectory }
                    .groupBy { it.path.substringBeforeLast('/', "") }
                    .toSortedMap()
                for ((dir, dirFiles) in filesByDir) {
                    val depth = if (dir.isBlank()) 0 else dir.split('/').size
                    val indent = "  ".repeat(depth)
                    tree.appendLine("$indent${dir.ifBlank { "." }}/")
                    for (entry in dirFiles.sortedBy { it.path }) {
                        val name = entry.path.substringAfterLast('/')
                        val ext = name.substringAfterLast('.', "")
                        val size = entry.size ?: 0
                        val sizeLabel = when {
                            size < 1024 -> "${size}B"
                            size < 1024 * 1024 -> "${size / 1024}KB"
                            else -> "${size / (1024 * 1024)}MB"
                        }
                        tree.appendLine("$indent  $name [$ext $sizeLabel]")
                    }
                }
                if (result.truncated) tree.appendLine("(truncated)")
                JSONObject()
                    .put("tree", tree.toString().trimEnd())
                    .put("truncated", result.truncated)
                    .toString()
            },
            "batch_read" to { call ->
                val arguments = call.arguments()
                val pathsJson = arguments.optJSONArray("paths")
                    ?: throw IllegalArgumentException("Tool argument paths must be a JSON array")
                require(pathsJson.length() in 1..20) { "batch_read accepts 1-20 paths" }
                val results = JSONArray()
                var totalChars = 0
                for (index in 0 until pathsJson.length()) {
                    val path = pathsJson.getString(index)
                    if (totalChars >= MAX_FILE_CHARS * 4) {
                        results.put(JSONObject().put("path", path).put("skipped", "budget exhausted"))
                        continue
                    }
                    val content = files.readText(LogicalPath.validate(path))
                    val contentOrError = if (content == null) {
                        JSONObject().put("path", path).put("exists", false)
                    } else {
                        val budget = MAX_FILE_CHARS * 4 - totalChars
                        val truncated = content.length > budget
                        val clipped = if (truncated) content.take(budget) else content
                        totalChars += clipped.length
                        JSONObject()
                            .put("path", path)
                            .put("exists", true)
                            .put("content", clipped)
                            .put("truncated", truncated)
                    }
                    results.put(contentOrError)
                }
                JSONObject().put("files", results).toString()
            },
            "apply_patch" to { call ->
                val arguments = call.arguments()
                val patchPath = arguments.requiredString("path")
                backups?.let { store -> files.readText(patchPath)?.let { store.save(patchPath, it) } }
                val result = files.applyPatch(
                    patchPath,
                    arguments.requiredString("patch"),
                )
                JSONObject()
                    .put("ok", true)
                    .put("hunks_applied", result.hunksApplied)
                    .put("characters_written", result.charactersWritten)
                    .toString()
            },
            "create_file" to writeHandler(backups, files) { files.createText(it.first, it.second) },
            "overwrite_file" to writeHandler(backups, files) { files.overwriteText(it.first, it.second) },
            "append_file" to writeHandler(backups, files) { files.appendText(it.first, it.second) },
        )

        if (backups != null) {
            runtime.register(
                plugin(manifests.first { it.name == "rollback_file" }) { call ->
                    val path = call.arguments().requiredString("path")
                    val content = backups.restore(path)
                    if (content == null) {
                        JSONObject()
                            .put("restored", false)
                            .put("path", path)
                            .put("reason", "no_backup")
                            .toString()
                    } else {
                        files.overwriteText(path, content)
                        backups.clear(path)
                        JSONObject()
                            .put("restored", true)
                            .put("path", path)
                            .toString()
                    }
                },
            )
        }

        if (shell != null) {
            val shellHandler: suspend (ToolCall) -> String = { call ->
                val arguments = call.arguments()
                val command = arguments.requiredString("command")
                val timeoutMs = if (arguments.has("timeout_ms") && !arguments.isNull("timeout_ms")) {
                    arguments.getLong("timeout_ms")
                } else {
                    15_000L
                }
                shell.execute(command, timeoutMs)
            }
            runtime.register(plugin(manifests.first { it.name == "run_command" }, shellHandler))
        }

        manifests.forEach { pluginManifest ->
            if (pluginManifest.name == "run_command" || pluginManifest.name == "rollback_file") return@forEach
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

    private fun writeHandler(
        backups: WorkspaceBackupStore?,
        files: SafWorkspaceFileExecutor,
        action: (Pair<String, String>) -> Unit,
    ): suspend (ToolCall) -> String = { call ->
        val arguments = call.arguments()
        val path = arguments.requiredString("path")
        backups?.let { store -> files.readText(path)?.let { store.save(path, it) } }
        action(path to arguments.requiredContent())
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
