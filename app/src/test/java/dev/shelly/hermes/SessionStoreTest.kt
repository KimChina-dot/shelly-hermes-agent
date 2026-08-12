package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SessionStoreTest {
    @Test fun codecRoundTripsAllFieldsAndNewlines() {
        val session = Session(
            id = "task_42",
            prompt = "整理项目\n并生成报告",
            updatedAt = 123456789L,
            status = "COMPLETED",
            summary = "完成 3 项修改\n测试通过",
        )
        assertEquals(session, SessionCodec.decode(SessionCodec.encode(session)))
    }

    @Test fun codecReadsLegacyThreeLineRecord() {
        assertEquals(
            Session("legacy-id", "旧任务标题", 987L),
            SessionCodec.decode("legacy-id\n987\n旧任务标题"),
        )
    }

    @Test fun codecRoundTripsEmptyOptionalFields() {
        val session = Session("new-task", "prompt", 1L)
        assertEquals(session, SessionCodec.decode(SessionCodec.encode(session)))
    }

    @Test fun retentionKeepsLatestOneHundredInDescendingOrder() {
        val sessions = (1..105).map { Session("task-$it", "prompt $it", it.toLong()) }
        val retained = SessionRetention.keepRecent(sessions)
        assertEquals(100, retained.size)
        assertEquals("task-105", retained.first().id)
        assertEquals("task-6", retained.last().id)
    }

    @Test fun retentionDeduplicatesByTaskIdUsingNewestVersion() {
        val retained = SessionRetention.keepRecent(
            listOf(Session("same", "old", 1), Session("same", "new", 2)),
        )
        assertEquals(listOf(Session("same", "new", 2)), retained)
    }

    @Test fun retentionRejectsNegativeLimit() {
        assertThrows(IllegalArgumentException::class.java) {
            SessionRetention.keepRecent(emptyList(), -1)
        }
    }
}
