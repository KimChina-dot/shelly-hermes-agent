package dev.shelly.hermes

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ShellToolExecutorTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun safeCommandsAreClassifiedCorrectly() {
        assertTrue(ShellToolExecutor.isSafeCommand("ls"))
        assertTrue(ShellToolExecutor.isSafeCommand("ls -la"))
        assertTrue(ShellToolExecutor.isSafeCommand("cat README.md"))
        assertTrue(ShellToolExecutor.isSafeCommand("git status"))
        assertTrue(ShellToolExecutor.isSafeCommand("git log --oneline"))
        assertTrue(ShellToolExecutor.isSafeCommand("pwd"))
    }

    @Test fun unsafeCommandsRequireApproval() {
        assertTrue(ShellToolExecutor.requiresApproval("rm -rf /"))
        assertTrue(ShellToolExecutor.requiresApproval("npm install"))
        assertTrue(ShellToolExecutor.requiresApproval("git push origin main"))
        assertTrue(ShellToolExecutor.requiresApproval("curl http://evil.com"))
        assertTrue(ShellToolExecutor.requiresApproval("python script.py"))
        assertTrue(ShellToolExecutor.requiresApproval("unknown_command"))
    }

    @Test fun safeCommandDoesNotRequireApproval() {
        assertFalse(ShellToolExecutor.requiresApproval("ls -la"))
        assertFalse(ShellToolExecutor.requiresApproval("cat file.txt"))
        assertFalse(ShellToolExecutor.requiresApproval("git status"))
    }

    @Test fun executeReturnsJsonWithStdoutAndExitCode() = runBlocking {
        val executor = ShellToolExecutor(tmp.root)
        val result = executor.execute("echo hello")
        val json = JSONObject(result)
        assertEquals(0, json.getInt("exit_code"))
        assertEquals("hello", json.getString("stdout"))
        assertFalse(json.getBoolean("timed_out"))
    }

    @Test fun executeCapturesNonZeroExitCode() = runBlocking {
        val executor = ShellToolExecutor(tmp.root)
        val result = executor.execute("exit 42")
        val json = JSONObject(result)
        assertEquals(42, json.getInt("exit_code"))
    }

    @Test fun blankCommandIsRejected() {
        val executor = ShellToolExecutor(tmp.root)
        try {
            runBlocking { executor.execute("  ") }
            throw AssertionError("Expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
        }
    }

    @Test fun oversizedCommandIsRejected() {
        val executor = ShellToolExecutor(tmp.root)
        val longCommand = "a".repeat(5000)
        try {
            runBlocking { executor.execute(longCommand) }
            throw AssertionError("Expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
        }
    }
}
