package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class LogicalPathTest {
    @Test fun acceptsLogicalPath() {
        assertEquals("sessions/a.json", LogicalPath.validate("sessions/a.json"))
        assertEquals("sessions/a.json", LogicalPath.validate("sessions\\a.json"))
    }

    @Test fun rejectsTraversalAndAmbiguousSegments() {
        listOf("../secret", "a/../secret", "a/./file", "a//file").forEach { path ->
            assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate(path) }
        }
    }

    @Test fun rejectsAbsolutePathsAndNul() {
        listOf("/etc/passwd", "C:/Windows/system.ini", "C:\\Windows\\system.ini", "a\u0000b").forEach { path ->
            assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate(path) }
        }
    }

    @Test fun rejectsBlankPath() {
        listOf("", "   ").forEach { path ->
            assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate(path) }
        }
    }
}
