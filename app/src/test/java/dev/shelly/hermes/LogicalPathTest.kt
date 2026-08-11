package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class LogicalPathTest {
    @Test fun acceptsAndNormalizesLogicalPaths() {
        assertEquals("sessions/a.json", LogicalPath.validate("sessions/a.json"))
        assertEquals("sessions/a.json", LogicalPath.validate("sessions\\a.json"))
        assertEquals("nested/deep/file.txt", LogicalPath.validate("nested\\deep/file.txt"))
    }

    @Test fun rejectsTraversalAndAmbiguousSegments() {
        listOf(
            "../secret",
            "a/../secret",
            "a/./file",
            "a//file",
            ".",
            "..",
            "a/.",
            "a/..",
            "a\\..\\secret",
        ).forEach { path ->
            assertThrows("Expected rejection for $path", IllegalArgumentException::class.java) {
                LogicalPath.validate(path)
            }
        }
    }

    @Test fun rejectsAbsolutePathsAndUris() {
        listOf(
            "/etc/passwd",
            "\\server\\share\\file",
            "C:/Windows/system.ini",
            "c:\\Windows\\system.ini",
            "content://provider/document/root:secret",
            "file:///etc/passwd",
        ).forEach { path ->
            assertThrows("Expected rejection for $path", IllegalArgumentException::class.java) {
                LogicalPath.validate(path)
            }
        }
    }

    @Test fun rejectsBlankPathAndNul() {
        listOf("", "   ", "a\u0000b", "\u0000").forEach { path ->
            assertThrows(IllegalArgumentException::class.java) { LogicalPath.validate(path) }
        }
    }

    @Test fun cannotEscapeRootAfterBackslashNormalization() {
        listOf(
            "..\\secret",
            "safe\\..\\secret",
            "safe\\.\\file",
            "safe\\\\file",
        ).forEach { path ->
            assertThrows("Expected rejection for $path", IllegalArgumentException::class.java) {
                LogicalPath.validate(path)
            }
        }
    }
}
