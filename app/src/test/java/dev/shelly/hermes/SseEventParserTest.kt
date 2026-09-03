package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SseEventParserTest {
    @Test fun parsesOpenAiDataEventsAndDoneMarker() {
        val events = mutableListOf<SseEvent>()
        val parser = SseEventParser(events::add)
        parser.acceptLine("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}")
        parser.acceptLine("")
        parser.acceptLine("data: [DONE]")
        parser.acceptLine("")

        assertEquals(2, events.size)
        assertFalse(events[0].isDone)
        assertEquals("{\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}", events[0].data)
        assertTrue(events[1].isDone)
    }

    @Test fun joinsMultipleDataLinesAndPreservesMetadata() {
        val events = mutableListOf<SseEvent>()
        val parser = SseEventParser(events::add)
        parser.acceptLine(": keepalive")
        parser.acceptLine("event: message")
        parser.acceptLine("id: chunk-7")
        parser.acceptLine("data: first")
        parser.acceptLine("data:second")
        parser.finish()

        assertEquals(listOf(SseEvent("first\nsecond", "message", "chunk-7")), events)
    }

    @Test fun ignoresEmptyEventsAndUnknownFields() {
        val events = mutableListOf<SseEvent>()
        val parser = SseEventParser(events::add)
        parser.acceptLine("retry: 1000")
        parser.acceptLine("")
        parser.finish()
        assertTrue(events.isEmpty())
    }
}
