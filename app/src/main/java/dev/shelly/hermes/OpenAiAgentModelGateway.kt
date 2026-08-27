package dev.shelly.hermes

import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.ModelGateway
import dev.shelly.hermes.core.ModelReply
import dev.shelly.hermes.core.StreamingModelGateway
import dev.shelly.hermes.core.ToolCall
import org.json.JSONException
import org.json.JSONArray
import org.json.JSONObject

private fun parseToolCallArguments(raw: String): String = try {
    JSONObject(raw.ifBlank { "{}" }).toString()
} catch (error: JSONException) {
    throw ModelGatewayException.InvalidResponse("Model returned malformed tool arguments", error)
}

/** Maps the portable agent model contract to an OpenAI-compatible chat-completions endpoint. */
class OpenAiAgentModelGateway(
    private val client: OpenAiModelGateway,
    private val mode: AgentMode = AgentMode.ACT,
    private val allowedToolNames: Set<String> = AndroidWorkspaceToolPlugins.manifests.mapTo(linkedSetOf<String>()) { it.name },
) : ModelGateway, StreamingModelGateway {
    private val assistantByToolCallId = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()

    init {
        require(allowedToolNames.isNotEmpty()) { "At least one model tool must be allowed" }
    }

    override suspend fun complete(messages: List<AgentMessage>): ModelReply {
        return completeStreaming(messages) { }
    }

    override suspend fun completeStreaming(
        messages: List<AgentMessage>,
        onDelta: (String) -> Unit,
    ): ModelReply {
        val request = JSONObject()
            .put("messages", buildRequestMessages(messages))
            .put("tools", enabledToolDefinitions(mode, allowedToolNames))
            .put("tool_choice", "auto")
            .put(
                "stream_options",
                JSONObject().put("include_usage", true),
            )

        val content = StringBuilder()
        val toolCallBuilders = linkedMapOf<Int, ToolCallChunk>()
        var inputTokens = 0
        var outputTokens = 0

        client.chatCompletionsStream(request.toString()) { event ->
            if (event.isDone) return@chatCompletionsStream
            val payload = try {
                JSONObject(event.data)
            } catch (error: JSONException) {
                throw ModelGatewayException.InvalidResponse(
                    "Model streaming response contained invalid JSON",
                    error,
                )
            }
            payload.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }?.let {
                throw ModelGatewayException.Upstream("Model streaming request failed: $it", null)
            }
            val delta = payload.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("delta")
            val contentDelta = delta?.opt("content")
            if (contentDelta is String && contentDelta.isNotEmpty()) {
                content.append(contentDelta)
                onDelta(contentDelta)
            }
            delta?.optJSONArray("tool_calls")?.let { calls ->
                for (index in 0 until calls.length()) {
                    val item = calls.optJSONObject(index) ?: continue
                    val position = item.optInt("index", toolCallBuilders.size)
                    val chunk = toolCallBuilders.getOrPut(position) { ToolCallChunk() }
                    item.optString("id").takeIf { it.isNotBlank() }?.let(chunk.id::append)
                    item.optJSONObject("function")?.let { function ->
                        function.optString("name").takeIf { it.isNotBlank() }?.let(chunk.name::append)
                        function.optString("arguments").takeIf { it.isNotBlank() }?.let(chunk.arguments::append)
                    }
                }
            }
            payload.optJSONObject("usage")?.let { usage ->
                inputTokens = usage.optInt("prompt_tokens", inputTokens)
                outputTokens = usage.optInt("completion_tokens", outputTokens)
            }
        }

        val toolCalls = toolCallBuilders.toSortedMap().map { (_, builder) -> builder.build() }
        val finalContent = content.toString()
        rememberAssistantForToolResults(finalContent, toolCalls)
        return ModelReply(
            content = if (toolCalls.isEmpty()) finalContent else "",
            toolCalls = toolCalls,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
        )
    }

    private fun buildRequestMessages(messages: List<AgentMessage>): JSONArray {
        val requestMessages = JSONArray()
        for (message in messages) {
            if (message.role == MessageRole.ASSISTANT && message.toolCalls.isNotEmpty()) {
                val assistant = message.toJson()
                val toolCalls = assistant.optJSONArray("tool_calls") ?: JSONArray()
                for (index in 0 until toolCalls.length()) {
                    val callId = toolCalls.getJSONObject(index).optString("id").takeIf { it.isNotBlank() }
                    if (callId != null) {
                        assistantByToolCallId[callId] = assistant
                    }
                }
            }
            requestMessages.put(message.toJson())
        }
        return requestMessages
    }

    private fun rememberAssistantForToolResults(content: String, toolCalls: List<ToolCall>) {
        if (toolCalls.isEmpty()) return
        val assistant = JSONObject()
            .put("role", "assistant")
            .put("content", content)
            .put("tool_calls", JSONArray().apply {
                toolCalls.forEach { call ->
                    put(
                        JSONObject()
                            .put("id", call.id)
                            .put("type", "function")
                            .put(
                                "function",
                                JSONObject()
                                    .put("name", call.name)
                                    .put("arguments", call.argumentsJson),
                            ),
                    )
                }
            })
        toolCalls.forEach { assistantByToolCallId[it.id] = assistant }
    }

    private fun AgentMessage.toJson(): JSONObject = JSONObject().apply {
        put("role", role.name.lowercase())
        if (role == MessageRole.ASSISTANT && toolCalls.isNotEmpty()) {
            put("content", if (content.isBlank()) JSONObject.NULL else content)
            put(
                "tool_calls",
                JSONArray().apply {
                    toolCalls.forEach { call ->
                        put(
                            JSONObject()
                                .put("id", call.id)
                                .put("type", "function")
                                .put(
                                    "function",
                                    JSONObject()
                                        .put("name", call.name)
                                        .put("arguments", call.argumentsJson),
                                ),
                        )
                    }
                },
            )
        } else {
            put("content", content)
        }
        if (role == MessageRole.TOOL) {
            val id = toolCallId?.takeIf { it.isNotBlank() }
                ?: throw ModelGatewayException.InvalidRequest("Tool result is missing toolCallId")
            put("tool_call_id", id)
        }
    }

    private fun parseToolCalls(values: JSONArray?): List<ToolCall> {
        if (values == null) return emptyList()
        return buildList {
            for (index in 0 until values.length()) {
                val item = values.optJSONObject(index)
                    ?: throw ModelGatewayException.InvalidResponse("tool_calls[$index] is not an object")
                val function = item.optJSONObject("function")
                    ?: throw ModelGatewayException.InvalidResponse("tool_calls[$index].function is missing")
                val id = item.optString("id")
                val name = function.optString("name")
                val arguments = parseToolCallArguments(function.optString("arguments", "{}"))
                if (id.isBlank() || name.isBlank()) {
                    throw ModelGatewayException.InvalidResponse("tool_calls[$index] has a blank id or name")
                }
                add(ToolCall(id, name, arguments))
            }
        }
    }

    private fun JSONObject.requiredString(name: String): String {
        val value = opt(name)
        return when (value) {
            is String -> value
            is Number -> value.toString()
            is Boolean -> value.toString()
            is JSONObject, is JSONArray -> value.toString()
            null -> throw ModelGatewayException.InvalidResponse("Missing required parameter \"$name\"")
            else -> throw ModelGatewayException.InvalidResponse("Unsupported parameter type for \"$name\"")
        }
    }

    private inner class ToolCallChunk {
        val id = StringBuilder()
        val name = StringBuilder()
        val arguments = StringBuilder()

        fun build(): ToolCall {
            val callId = id.toString()
            val callName = name.toString()
            if (callId.isBlank() || callName.isBlank()) {
                throw ModelGatewayException.InvalidResponse("Model streaming response had incomplete tool call")
            }
            return ToolCall(callId, callName, parseToolCallArguments(arguments.toString()))
        }
    }

    companion object {
        private fun enabledToolDefinitions(
            mode: AgentMode,
            allowedToolNames: Set<String> = AndroidWorkspaceToolPlugins.manifests.mapTo(hashSetOf()) { it.name },
        ): JSONArray {
            val enabled = AndroidWorkspaceToolPlugins.manifests.mapTo(hashSetOf()) { it.name }
            val definitions = if (mode == AgentMode.PLAN) PLAN_TOOL_DEFINITIONS else TOOL_DEFINITIONS
            return JSONArray().apply {
                for (index in 0 until definitions.length()) {
                    val definition = definitions.getJSONObject(index)
                    val name = definition.getJSONObject("function").getString("name")
                    if (name in enabled && name in allowedToolNames) {
                        put(definition)
                    }
                }
            }
        }

        internal fun toolDefinitionNames(mode: AgentMode): Set<String> = buildSet {
            val definitions = enabledToolDefinitions(mode)
            for (index in 0 until definitions.length()) {
                add(definitions.getJSONObject(index).getJSONObject("function").getString("name"))
            }
        }

        private val PLAN_TOOL_DEFINITIONS = JSONArray().apply {
            put(tool("read_file", "Read a UTF-8 text file inside the selected workspace", false))
            put(tool("exists", "Check whether a path exists inside the selected workspace", false))
            put(
                toolWithProperties(
                    name = "list_files",
                    description = "Recursively list files and directories below a workspace-relative directory",
                    properties = JSONObject()
                        .put("path", JSONObject().put("type", "string").put("description", "Optional workspace-relative directory; omit for workspace root"))
                        .put("max_results", JSONObject().put("type", "integer").put("minimum", 1).put("maximum", 500)),
                    required = JSONArray(),
                ),
            )
            put(
                toolWithProperties(
                    name = "search_files",
                    description = "Search UTF-8 text files for a case-insensitive literal string",
                    properties = JSONObject()
                        .put("query", JSONObject().put("type", "string").put("minLength", 1).put("maxLength", 512))
                        .put("path", JSONObject().put("type", "string").put("description", "Optional workspace-relative directory"))
                        .put("max_results", JSONObject().put("type", "integer").put("minimum", 1).put("maximum", 100)),
                    required = JSONArray().put("query"),
                ),
            )
        }

        private val TOOL_DEFINITIONS = JSONArray().apply {
            put(tool("read_file", "Read a UTF-8 text file inside the selected workspace", false))
            put(tool("exists", "Check whether a path exists inside the selected workspace", false))
            put(
                toolWithProperties(
                    name = "list_files",
                    description = "Recursively list files and directories below a workspace-relative directory",
                    properties = JSONObject()
                        .put("path", JSONObject().put("type", "string").put("description", "Optional workspace-relative directory; omit for workspace root"))
                        .put("max_results", JSONObject().put("type", "integer").put("minimum", 1).put("maximum", 500)),
                    required = JSONArray(),
                ),
            )
            put(
                toolWithProperties(
                    name = "search_files",
                    description = "Search UTF-8 text files for a case-insensitive literal string",
                    properties = JSONObject()
                        .put("query", JSONObject().put("type", "string").put("minLength", 1).put("maxLength", 512))
                        .put("path", JSONObject().put("type", "string").put("description", "Optional workspace-relative directory"))
                        .put("max_results", JSONObject().put("type", "integer").put("minimum", 1).put("maximum", 100)),
                    required = JSONArray().put("query"),
                ),
            )
            put(
                toolWithProperties(
                    name = "repo_map",
                    description = "Generate a compact project tree with file names, extensions, and sizes for context",
                    properties = JSONObject()
                        .put("max_results", JSONObject().put("type", "integer").put("minimum", 1).put("maximum", 500).put("description", "Maximum files to show (default 100)")),
                    required = JSONArray(),
                ),
            )
            put(
                toolWithProperties(
                    name = "batch_read",
                    description = "Read up to 20 files in one call to reduce round trips; each file is capped and may be truncated",
                    properties = JSONObject()
                        .put("paths", JSONObject()
                            .put("type", "array")
                            .put("items", JSONObject().put("type", "string"))
                            .put("minItems", 1)
                            .put("maxItems", 20)
                            .put("description", "Workspace-relative file paths to read")),
                    required = JSONArray().put("paths"),
                ),
            )
            put(
                toolWithProperties(
                    name = "run_command",
                    description = "Run a shell command in the app sandbox and return stdout, stderr, and exit code",
                    properties = JSONObject()
                        .put("command", JSONObject().put("type", "string").put("description", "Shell command to execute").put("minLength", 1))
                        .put("timeout_ms", JSONObject().put("type", "integer").put("description", "Optional timeout in milliseconds (1000-30000, default 15000)").put("minimum", 1000).put("maximum", 30000)),
                    required = JSONArray().put("command"),
                ),
            )
            put(
                toolWithProperties(
                    name = "apply_patch",
                    description = "Apply a unified diff to an existing UTF-8 file; fails if old context is stale",
                    properties = JSONObject()
                        .put("path", JSONObject().put("type", "string").put("description", "Workspace-relative logical path"))
                        .put("patch", JSONObject().put("type", "string").put("description", "Unified diff containing one or more @@ hunks")),
                    required = JSONArray().put("path").put("patch"),
                ),
            )
            put(tool("create_file", "Create a new UTF-8 text file", true))
            put(tool("overwrite_file", "Create or replace a UTF-8 text file", true))
            put(tool("append_file", "Append UTF-8 text to a file", true))
        }

        private fun tool(name: String, description: String, needsContent: Boolean): JSONObject {
            val properties = JSONObject()
                .put("path", JSONObject().put("type", "string").put("description", "Workspace-relative logical path"))
            val required = JSONArray().put("path")
            if (needsContent) {
                properties.put("content", JSONObject().put("type", "string"))
                required.put("content")
            }
            return toolWithProperties(name, description, properties, required)
        }

        private fun toolWithProperties(
            name: String,
            description: String,
            properties: JSONObject,
            required: JSONArray,
        ): JSONObject {
            return JSONObject()
                .put("type", "function")
                .put(
                    "function",
                    JSONObject()
                        .put("name", name)
                        .put("description", description)
                        .put(
                            "parameters",
                            JSONObject()
                                .put("type", "object")
                                .put("properties", properties)
                                .put("required", required)
                                .put("additionalProperties", false),
                        ),
                )
        }
    }
}
