package dev.shelly.hermes

import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.PendingToolCall
import dev.shelly.hermes.core.MessageRole
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolExecutionStage
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SessionEventStoreTest {
    @Test fun appendsAndLoadsCheckpointInSequence() {
        val directory = Files.createTempDirectory("luma-events").toFile()
        var now = 10L
        val store = SessionEventStore(directory, "session-1") { now++ }
        store.append(SessionEvent(SessionEventType.SESSION_STARTED, "prompt"))
        store.append(SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint("hello")))

        val restored = SessionEventStore(directory, "session-1").load()
        assertEquals(listOf(1L, 2L), restored.map { it.sequence })
        assertEquals(listOf(10L, 11L), restored.map { it.timestamp })
        assertEquals("hello", store.latestCheckpoint()!!.messages.single().content)
        assertEquals("hello", store.deriveMessages().single().content)
    }

    @Test fun forkRestoresLatestCheckpointAtRequestedSequence() {
        val directory = Files.createTempDirectory("luma-events-fork").toFile()
        val source = SessionEventStore(directory, "source")
        source.append(SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint("one")))
        source.append(SessionEvent(SessionEventType.STATUS, "RUNNING"))
        source.append(SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint("three")))

        val fork = source.fork("fork", 2L)

        assertEquals("one", fork.latestCheckpoint()!!.messages.single().content)
        assertEquals(SessionEventType.FORKED, fork.load().first().event.type)
        assertEquals("source", fork.load().first().event.sourceSessionId)
    }

    @Test fun rejectsCorruptOrOutOfOrderRecords() {
        val directory = Files.createTempDirectory("luma-events-corrupt").toFile()
        val store = SessionEventStore(directory, "broken")
        store.append(SessionEvent(SessionEventType.STATUS, "RUNNING"))
        directory.listFiles()!!.single { it.extension == "jsonl" }
            .appendText("{not-json}\n")

        assertThrows(SessionEventCorruptionException::class.java) { store.load() }
    }

    @Test fun codecPreservesNewlinesAndToolCallIds() {
        val checkpoint = AgentCheckpoint(
            messages = listOf(AgentMessage(MessageRole.TOOL, "line 1\nline 2", "call-1")),
            round = 2,
            consumedTokens = 30,
            toolCalls = 1,
        )
        val envelope = SessionEventEnvelope(
            sessionId = "session-json",
            sequence = 1,
            timestamp = 5,
            event = SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint),
        )

        assertEquals(envelope, SessionEventCodec.decode(SessionEventCodec.encode(envelope)))
    }

    @Test fun codecPreservesAssistantToolCallsAndPendingWork() {
        val checkpoint = AgentCheckpoint(
            messages = listOf(
                AgentMessage(
                    MessageRole.ASSISTANT,
                    "",
                    toolCalls = listOf(ToolCall("call-1", "apply_patch", "{\"path\":\"a.txt\"}")),
                ),
            ),
            round = 1,
            consumedTokens = 5,
            toolCalls = 1,
            pendingToolCalls = listOf(
                PendingToolCall(ToolCall("call-1", "apply_patch", "{}"), ToolExecutionStage.RUNNING),
            ),
        )
        val envelope = SessionEventEnvelope("session-v2", 1, 5, SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint))

        val restored = SessionEventCodec.decode(SessionEventCodec.encode(envelope))

        assertEquals(checkpoint, restored.event.checkpoint)
    }

    @Test fun codecPreservesAssistantToolCallsAndPendingQueue() {
        val checkpoint = AgentCheckpoint(
            messages = listOf(
                AgentMessage(
                    MessageRole.ASSISTANT,
                    "",
                    toolCalls = listOf(ToolCall("call-2", "apply_patch", "{\"path\":\"a.txt\"}")),
                ),
                AgentMessage(MessageRole.TOOL, "applied", "call-2"),
            ),
            round = 3,
            consumedTokens = 20,
            toolCalls = 1,
            pendingToolCalls = listOf(
                PendingToolCall(ToolCall("call-3", "create_file", "{}"), ToolExecutionStage.AWAITING_EXECUTION),
            ),
        )
        val envelope = SessionEventEnvelope(
            "session-v2",
            1,
            3,
            SessionEvent(SessionEventType.CHECKPOINT, checkpoint = checkpoint),
        )

        assertEquals(envelope, SessionEventCodec.decode(SessionEventCodec.encode(envelope)))
    }

    @Test fun codecReadsVersionOneCheckpoint() {
        val json = """
            {"version":1,"sessionId":"session-v1","sequence":1,"timestamp":4,
             "type":"CHECKPOINT","detail":"","checkpoint":{"round":2,"consumedTokens":8,
             "toolCalls":1,"messages":[{"role":"ASSISTANT","content":"doing"},{"role":"TOOL","content":"done","toolCallId":"call-1"}]}}
        """.trimIndent()

        val checkpoint = SessionEventCodec.decode(json).event.checkpoint!!
        assertEquals(2, checkpoint.round)
        assertEquals("doing", checkpoint.messages[0].content)
        assertEquals("call-1", checkpoint.messages[1].toolCallId)
        assertEquals(0, checkpoint.messages[0].toolCalls.size)
        assertEquals(0, checkpoint.pendingToolCalls.size)
    }

    private fun checkpoint(content: String) = AgentCheckpoint(
        messages = listOf(AgentMessage(MessageRole.USER, content)),
        round = 1,
        consumedTokens = 2,
        toolCalls = 0,
    )
}
