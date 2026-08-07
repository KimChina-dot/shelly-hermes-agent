package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class LogicalPathTest {
    @Test fun acceptsLogicalPath() { assertEquals("sessions/a.json", LogicalPath.validate("sessions/a.json")) }
    @Test fun rejectsTraversal() { assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate("../secret") } }
    @Test fun rejectsAbsoluteAndNul() { assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate("/etc/passwd") }; assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate("a\u0000b") } }
}
