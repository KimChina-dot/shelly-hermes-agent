package dev.shelly.hermes

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AgentTaskQueueStoreTest {
    @Test fun enqueueIsIdempotentAndClaimsInOrder() {
        val store = AgentTaskQueueStore(Files.createTempDirectory("luma-queue").toFile())
        val first = task("one", 1)
        store.enqueue(first)
        store.enqueue(first.copy(prompt = "changed"))
        store.enqueue(task("two", 2))

        assertEquals(2, store.list().size)
        assertEquals("one", store.claimNext()!!.id)
        assertEquals("two", store.claimNext()!!.id)
        assertEquals(null, store.claimNext())
    }

    @Test fun recoversRunningWorkAndPreservesAttempts() {
        val directory = Files.createTempDirectory("luma-queue-recovery").toFile()
        val store = AgentTaskQueueStore(directory)
        store.enqueue(task("one", 1))
        assertEquals(1, store.claimNext()!!.attempts)

        assertEquals(1, AgentTaskQueueStore(directory).recoverInterrupted())
        val recovered = AgentTaskQueueStore(directory).claimNext()!!
        assertEquals("one", recovered.id)
        assertEquals(2, recovered.attempts)
    }

    @Test fun terminalStateRoundTripsAndCannotBeClaimedAgain() {
        val store = AgentTaskQueueStore(Files.createTempDirectory("luma-queue-finish").toFile())
        store.enqueue(task("one", 1))
        store.claimNext()
        store.finish("one", QueuedTaskState.COMPLETED, "done")

        assertEquals(QueuedTaskState.COMPLETED, store.list().single().state)
        assertEquals("done", store.list().single().detail)
        assertEquals(null, store.claimNext())
    }

    @Test fun pendingTasksCanBeCancelledAndTerminalTasksRetried() {
        val store = AgentTaskQueueStore(Files.createTempDirectory("luma-queue-actions").toFile())
        store.enqueue(task("cancel", 1))
        assertEquals(true, store.cancelPending("cancel"))
        assertEquals(QueuedTaskState.CANCELLED, store.list().single().state)
        assertEquals(true, store.retry("cancel"))
        assertEquals("cancel", store.claimNext()!!.id)
        assertEquals(false, store.cancelPending("cancel"))
    }

    @Test fun explicitResumeRequeuesAnExistingTerminalSession() {
        val store = AgentTaskQueueStore(Files.createTempDirectory("luma-queue-resume").toFile())
        store.enqueue(task("session", 1))
        store.claimNext()
        store.finish("session", QueuedTaskState.COMPLETED)
        val resumed = store.enqueue(
            task("session", 2).copy(action = QueuedTaskAction.RESUME, prompt = ""),
        )
        assertEquals(QueuedTaskState.PENDING, resumed.state)
        assertEquals(QueuedTaskAction.RESUME, store.claimNext()!!.action)
    }

    @Test fun codecPreservesForkAndRejectsCorruption() {
        val fork = QueuedAgentTask(
            id = "fork-1",
            action = QueuedTaskAction.FORK,
            prompt = "",
            mode = AgentMode.ACT,
            profileId = "coding",
            createdAt = 3,
            sourceSessionId = "source",
            sourceSequence = 9,
        )
        assertEquals(listOf(fork), AgentTaskQueueCodec.decode(AgentTaskQueueCodec.encode(listOf(fork))))
        assertThrows(Exception::class.java) { AgentTaskQueueCodec.decode("not-json") }
    }

    private fun task(id: String, createdAt: Long) = QueuedAgentTask(
        id = id,
        action = QueuedTaskAction.START,
        prompt = "do $id",
        mode = AgentMode.ACT,
        profileId = "coding",
        createdAt = createdAt,
    )
}
