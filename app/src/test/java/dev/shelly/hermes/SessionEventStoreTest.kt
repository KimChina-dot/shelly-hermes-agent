package dev.shelly.hermes

import dev.shelly.hermes.core.AgentCheckpoint
import dev.shelly.hermes.core.AgentMessage
import dev.shelly.hermes.core.MessageRole
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

    private fun checkpoint(content: String) = AgentCheckpoint(
        messages = listOf(AgentMessage(MessageRole.USER, content)),
        round = 1,
        consumedTokens = 2,
        toolCalls = 0,
    )
}
