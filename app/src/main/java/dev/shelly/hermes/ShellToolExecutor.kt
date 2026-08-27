package dev.shelly.hermes

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Sandboxed shell tool for Android using ProcessBuilder + toybox/sh.
 *
 * Commands run inside the app-private working directory. No root, no adb, no host access.
 * Output is capped to prevent OOM. Timeout prevents runaway processes.
 */
class ShellToolExecutor(
    private val workingDirectory: File,
    private val defaultTimeoutMs: Long = 15_000L,
    private val maxTimeoutMs: Long = 30_000L,
    private val maxOutputChars: Int = 32_000,
) {

    suspend fun execute(command: String, timeoutMs: Long = defaultTimeoutMs): String {
        require(command.isNotBlank()) { "Command must not be blank" }
        require(command.length <= MAX_COMMAND_LENGTH) {
            "Command exceeds ${MAX_COMMAND_LENGTH} characters"
        }
        val boundedTimeout = timeoutMs.coerceIn(1_000L, maxTimeoutMs)

        return withContext(Dispatchers.IO) {
            withTimeout(boundedTimeout + 2_000L) {
                val process = ProcessBuilder(SHELL_PATH, "-c", command)
                    .directory(workingDirectory)
                    .redirectErrorStream(false)
                    .start()

                val stdout = StringBuilder()
                val stderr = StringBuilder()
                var truncated = false

                val finished = process.waitFor(boundedTimeout, TimeUnit.MILLISECONDS)
                if (!finished) {
                    process.destroyForcibly()
                    return@withTimeout JSONObject()
                        .put("exit_code", -1)
                        .put("stdout", "")
                        .put("stderr", "Command timed out after ${boundedTimeout}ms")
                        .put("timed_out", true)
                        .toString()
                }

                process.inputStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                    if (stdout.length + line.length + 1 <= maxOutputChars) {
                        stdout.appendLine(line)
                    } else {
                        truncated = true
                    }
                }
                process.errorStream.bufferedReader(Charsets.UTF_8).forEachLine { line ->
                    if (stderr.length + line.length + 1 <= maxOutputChars) {
                        stderr.appendLine(line)
                    } else {
                        truncated = true
                    }
                }

                JSONObject()
                    .put("exit_code", process.exitValue())
                    .put("stdout", stdout.toString().trimEnd())
                    .put("stderr", stderr.toString().trimEnd())
                    .put("timed_out", false)
                    .put("truncated", truncated)
                    .toString()
            }
        }
    }

    companion object {
        private const val SHELL_PATH = "/system/bin/sh"
        private const val MAX_COMMAND_LENGTH = 4_096

        /** Commands safe enough for agent auto-execution without user approval. */
        val SAFE_COMMAND_PREFIXES = setOf(
            "ls", "cat", "head", "tail", "wc", "find", "grep", "rg",
            "pwd", "echo", "date", "stat", "file", "du", "df",
            "git status", "git log", "git diff", "git branch",
            "git rev-parse", "git show", "git ls-files",
        )

        /** Commands that always require explicit user approval. */
        val APPROVAL_REQUIRED_PREFIXES = setOf(
            "git commit", "git push", "git pull", "git merge", "git rebase",
            "git checkout", "git reset", "git stash", "git rm",
            "rm", "mv", "cp", "mkdir", "rmdir", "touch", "chmod", "chown",
            "npm", "npx", "node", "python", "python3", "pip", "java", "javac",
            "gradle", "./gradlew", "make", "cmake", "cargo", "go",
        )

        fun isSafeCommand(command: String): Boolean {
            val trimmed = command.trim()
            return SAFE_COMMAND_PREFIXES.any { prefix ->
                trimmed == prefix || trimmed.startsWith("$prefix ") || trimmed.startsWith("$prefix\t")
            }
        }

        fun requiresApproval(command: String): Boolean {
            val trimmed = command.trim()
            return APPROVAL_REQUIRED_PREFIXES.any { prefix ->
                trimmed == prefix || trimmed.startsWith("$prefix ") || trimmed.startsWith("$prefix\t")
            } || !isSafeCommand(trimmed)
        }
    }
}
