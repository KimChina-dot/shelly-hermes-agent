package dev.shelly.hermes

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class McpServerConfig(
    val name: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
) {
    init {
        require(name.isNotBlank()) { "MCP server name must not be blank" }
        require(url.startsWith("https://") || url.startsWith("http://")) {
            "MCP server URL must be http(s): $url"
        }
    }
}

/** Reads the MCP server list from a standard .mcp.json at the workspace root. */
fun interface McpConfigProvider {
    suspend fun servers(): List<McpServerConfig>

    companion object {
        fun fromWorkspace(files: SafWorkspaceFileExecutor): McpConfigProvider =
            McpConfigProvider {
                val raw = files.readText(".mcp.json") ?: return@McpConfigProvider emptyList()
                parseMcpConfig(raw)
            }
    }
}

fun parseMcpConfig(raw: String): List<McpServerConfig> {
    val root = JSONObject(raw)
    val servers = root.optJSONObject("mcpServers") ?: JSONObject()
    val names = servers.names() ?: JSONArray()
    val result = mutableListOf<McpServerConfig>()
    for (index in 0 until names.length()) {
        val name = names.getString(index)
        val server = servers.getJSONObject(name)
        val headerObject = server.optJSONObject("headers")
        val headers = if (headerObject != null) {
            val names = headerObject.names() ?: JSONArray()
            val map = mutableMapOf<String, String>()
            for (index in 0 until names.length()) {
                val key = names.getString(index)
                map[key] = headerObject.getString(key)
            }
            map
        } else {
            emptyMap()
        }
        result += McpServerConfig(
            name = name,
            url = server.getString("url"),
            headers = headers,
        )
    }
    return result
}

class McpClient(
    private val timeoutMillis: Long = 20_000L,
) {
    suspend fun listTools(server: McpServerConfig): JSONArray = withContext(Dispatchers.IO) {
        val reply = post(server, "tools/list", JSONObject())
        reply.optJSONArray("tools") ?: JSONArray()
    }

    suspend fun callTool(
        server: McpServerConfig,
        toolName: String,
        arguments: JSONObject,
    ): JSONObject = withContext(Dispatchers.IO) {
        val params = JSONObject()
            .put("name", toolName)
            .put("arguments", arguments)
        post(server, "tools/call", params)
    }

    private fun post(server: McpServerConfig, method: String, params: JSONObject): JSONObject {
        val id = java.util.UUID.randomUUID().toString()
        val body = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", id)
            .put("method", method)
            .put("params", params)
            .toString()
        val connection = URL(server.url).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = timeoutMillis.toInt()
        connection.readTimeout = timeoutMillis.toInt()
        connection.doOutput = true
        connection.setRequestProperty("Accept", "application/json, text/event-stream")
        connection.setRequestProperty("Content-Type", "application/json")
        server.headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        val code = connection.responseCode
        if (code !in 200..299) {
            val detail = connection.errorStream?.readBytes()?.toString(Charsets.UTF_8).orEmpty()
            throw IllegalStateException("MCP HTTP error $code: ${detail.take(512)}")
        }
        val contentType = connection.contentType.orEmpty().lowercase()
        val payload = connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
        val root = if (contentType.contains("text/event-stream") || payload.startsWith("event:")) {
            parseSsePayload(payload)
        } else {
            JSONObject(payload)
        }
        if (root.has("error")) {
            throw IllegalStateException("MCP $method failed: ${root.getJSONObject("error").optString("message")}")
        }
        return root.optJSONObject("result") ?: root
    }

    private fun parseSsePayload(payload: String): JSONObject {
        val json = payload.lineSequence()
            .filter { it.startsWith("data:") }
            .map { it.removePrefix("data:").trim() }
            .joinToString("")
        if (json.isBlank()) {
            throw IllegalStateException("MCP SSE response contained no data")
        }
        return JSONObject(json)
    }
}

/** Facade the agent uses for MCP servers configured in .mcp.json. */
class McpToolBridge(
    private val provider: McpConfigProvider,
    private val client: McpClient = McpClient(),
) {
    suspend fun servers(): List<McpServerConfig> = provider.servers()

    suspend fun listTools(serverName: String): JSONArray {
        val server = provider.servers().firstOrNull { it.name == serverName }
            ?: throw IllegalArgumentException("MCP server '$serverName' is not configured")
        return client.listTools(server)
    }

    suspend fun call(serverName: String, toolName: String, arguments: JSONObject): JSONObject {
        val server = provider.servers().firstOrNull { it.name == serverName }
            ?: throw IllegalArgumentException("MCP server '$serverName' is not configured")
        return client.callTool(server, toolName, arguments)
    }
}
