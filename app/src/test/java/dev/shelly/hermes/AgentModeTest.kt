package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentModeTest {
    @Test fun parsesWireValuesAndDefaultsSafely() {
        assertEquals(AgentMode.PLAN, AgentMode.fromWireValue("plan"))
        assertEquals(AgentMode.ACT, AgentMode.fromWireValue("ACT"))
        assertEquals(AgentMode.ACT, AgentMode.fromWireValue(null))
        assertEquals(AgentMode.ACT, AgentMode.fromWireValue("unknown"))
    }
}
