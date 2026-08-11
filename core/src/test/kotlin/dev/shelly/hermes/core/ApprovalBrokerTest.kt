package dev.shelly.hermes.core

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ApprovalBrokerTest {

    @Test
    fun `request suspends until resolve approves`() = runTest {
        val broker = ApprovalBroker()
        val call = ToolCall("1", "edit_file", "{}")
        val launched = mutableListOf<PendingApproval>()
        broker.launcher = { launched += it }

        var decision: ApprovalDecision? = null
        val job = launch { decision = broker.request(call) }

        // No decision yet: the coroutine is suspended.
        assertEquals(1, launched.size)
        assertNull(decision)
        assertSame(call, broker.active?.call)
        assertNull(decision)

        // Resolve and let the coroutine resume.
        assertTrue(broker.resolve(ApprovalDecision.APPROVE))
        job.join()
        assertEquals(ApprovalDecision.APPROVE, decision)
        assertNull(broker.active)
    }

    @Test
    fun `resolve without pending request is a no-op`() {
        val broker = ApprovalBroker()
        assertFalse(broker.resolve(ApprovalDecision.REJECT))
    }

    @Test
    fun `launcher receives the pending tool call`() = runTest {
        val broker = ApprovalBroker()
        val call = ToolCall("7", "run_process", """{"cmd":"rm -rf /tmp/x"}""")
        var received: PendingApproval? = null
        broker.launcher = { received = it }

        val job = launch { broker.request(call) }
        assertEquals(call, received?.call)
        broker.resolve(ApprovalDecision.REJECT)
        job.join()
    }
}