package dev.shelly.hermes

import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.ModelGateway
import dev.shelly.hermes.core.ModelReply
import dev.shelly.hermes.core.ToolCall
import org.json.JSONArray
import org.json.JSONObject

/** Maps the portable agent model contract to an OpenAI-compatible chat-completions endpoint. */
class OpenAiAgentModelGateway(
    private val client: OpenAiModelGateway,
) : ModelGateway {
    private val assistantByToolCallId = mutableMapOf<String, JSONObject>()

    override suspend fun complete(messages: List<AgentMessage>): ModelReply {
        val requestMessages = JSONArray()
        val emittedAssistantMessages = mutableSetOf<String>()
        for (message in messages) {
            if (message.role == MessageRole.TOOL) {
                val assistant = message.toolCallId?.let(assistantByToolCallId::get)
                val serialized = assistant?.toString()
                if (assistant != null && serialized != null && emittedAssistantMessages.add(serialized)) {
                    requestMessages.put(assistant)
                }
            }
            requestMessages.put(message.toJson())
        }

        val request = JSONObject()
            .put("messages", requestMessages)
            .put("tools", TOOL_DEFINITIONS)
            .put("tool_choice", "auto")

        val response = JSONObject(client.chatCompletions(request.toString()))
        val choices = response.optJSONArray("choices")
            ?: throw ModelGatewayException.InvalidResponse("Model response is missing choices")
        if (choices.length() == 0) {
            throw ModelGatewayException.InvalidResponse("Model response contains no choices")
        }
        val message = choices.optJSONObject(0)?.optJSONObject("message")
            ?: throw ModelGatewayException.InvalidResponse("Model response is missing choices[0].message")

        val toolCalls = parseToolCalls(message.optJSONArray("tool_calls"))
        if (toolCalls.isNotEmpty()) {
            val assistant = JSONObject(message.toString())
            toolCalls.forEach { assistantByToolCallId[it.id] = assistant }
        }
        val usage = response.optJSONObject("usage")
        return ModelReply(
            content = if (toolCalls.isEmpty()) {
                message.optString("content").takeUnless { it == "null" }.orEmpty()
            } else {
                ""
            },
            toolCalls = toolCalls,
            inputTokens = usage?.optInt("prompt_tokens", 0) ?: 0,
            outputTokens = usage?.optInt("completion_tokens", 0) ?: 0,
        )
    }

    private fun AgentMessage.toJson(): JSONObject = JSONObject().apply {
        put("role", role.name.lowercase())
        put("content", content)
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
                val arguments = function.optString("arguments", "{}")
                if (id.isBlank() || name.isBlank()) {
                    throw ModelGatewayException.InvalidResponse("tool_calls[$index] has a blank id or name")
                }
                add(ToolCall(id, name, arguments))
            }
        }
    }

    companion object {
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
