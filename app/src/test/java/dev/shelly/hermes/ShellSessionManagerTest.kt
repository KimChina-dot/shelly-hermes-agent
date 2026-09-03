package dev.shelly.hermes

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ShellSessionManagerTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun echoCreatesPollableSession() {
        val manager = ShellSessionManager(tmp.root)
        val id = manager.start("echo hello; exit 7")
        Thread.sleep(400)
        val poll = JSONObject(manager.poll(id))
        assertTrue(poll.getBoolean("exists"))
        assertFalse(poll.getBoolean("running"))
        assertEquals(7, poll.getInt("exit_code"))
        assertEquals("hello", poll.getString("stdout").trim())
        manager.shutdown()
    }

    @Test
    fun cancelStopsLongRunningSession() {
        val manager = ShellSessionManager(tmp.root)
        val id = manager.start("sleep 20")
        val result = JSONObject(manager.cancel(id))
        assertTrue(result.getBoolean("cancelled"))
        assertTrue(manager.sessions().isEmpty())
        manager.shutdown()
    }
}
