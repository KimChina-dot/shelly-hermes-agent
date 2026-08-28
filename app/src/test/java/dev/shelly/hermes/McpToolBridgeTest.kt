package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class McpToolBridgeTest {
    @Test fun parsesStandardMcpConfig() {
        val raw = """
            {
              "mcpServers": {
                "github": {
                  "url": "https://mcp.example.com/github",
                  "headers": {"Authorization": "Bearer abc"}
                },
                "docs": {
                  "url": "https://mcp.example.com/docs"
                }
              }
            }
        """.trimIndent()
        val servers = parseMcpConfig(raw)
        assertEquals(2, servers.size)
        val github = servers.first { it.name == "github" }
        assertEquals("https://mcp.example.com/github", github.url)
        assertEquals("Bearer abc", github.headers["Authorization"])
    }

    @Test fun rejectsInvalidMcpUrl() {
        val raw = """{"mcpServers":{"bad":{"url":"ftp://x"}}}"""
        try {
            parseMcpConfig(raw)
            throw AssertionError("Expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test fun emptyConfigIsAllowed() {
        assertTrue(parseMcpConfig("""{"mcpServers":{}}""").isEmpty())
    }
}
