package dev.shelly.hermes.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ToolPluginRuntimeTest {
    @Test
    fun `registers starts executes and stops plugin through ToolExecutor`() = runTest {
        val events = mutableListOf<String>()
        val plugin = plugin(name = "read_file", capability = "fs.read", handler = { "read:${it.id}" }, events = events)
        val runtime = ToolPluginRuntime(ToolCapabilityAuthorizer.granted(setOf("fs.read")))

        runtime.register(plugin)
        assertEquals(listOf(plugin.manifest), runtime.manifests())
        assertEquals(ToolPluginLifecycle.STOPPED, runtime.status("read_file").lifecycle)
        runtime.start("read_file")
        assertEquals("read:1", runtime.asToolExecutor().execute(ToolCall("1", "read_file", "{}")))
        runtime.stop("read_file")

        assertEquals(listOf("start", "execute", "stop"), events)
        assertEquals(ToolPluginLifecycle.STOPPED, runtime.status("read_file").lifecycle)
    }

    @Test
    fun `rejects duplicate names and undeclared host capability`() = runTest {
        val runtime = ToolPluginRuntime(ToolCapabilityAuthorizer.granted(setOf("fs.read")))
        runtime.register(plugin("shell", "process.run"))
        val duplicate = assertFailsWith<ToolPluginException> { runtime.register(plugin("shell", "process.safe")) }
        assertEquals(ToolPluginErrorCode.ALREADY_REGISTERED, duplicate.code)
        runtime.start("shell")

        val denied = assertFailsWith<ToolPluginException> {
            runtime.execute(ToolCall("1", "shell", "{}"))
        }
        assertEquals(ToolPluginErrorCode.CAPABILITY_DENIED, denied.code)

        val declared = ToolPluginRuntime()
        declared.register(plugin("reader", "fs.read"))
        declared.start("reader")
        val mismatch = assertFailsWith<ToolPluginException> {
            declared.execute(ToolCall("2", "reader", "{}"), "fs.write")
        }
        assertEquals(ToolPluginErrorCode.CAPABILITY_DENIED, mismatch.code)
    }

    @Test
    fun `enforces timeout and truncates string output`() = runTest {
        val waitForever = CompletableDeferred<Unit>()
        val runtime = ToolPluginRuntime()
        runtime.register(plugin("slow", timeoutMillis = 25, maxOutputChars = 20) {
            waitForever.await()
            "unused"
        })
        runtime.register(plugin("large", maxOutputChars = 20) { "abcdefghijklmnopqrstuvwxyz" })
        runtime.startAll()

        assertFailsWith<TimeoutCancellationException> { runtime.execute(ToolCall("1", "slow", "{}")) }
        val truncated = runtime.execute(ToolCall("2", "large", "{}"))
        assertEquals(20, truncated.length)
        assertTrue(truncated.endsWith("...[truncated]"))
    }

    @Test
    fun `opens circuit after consecutive failures and recovers through half open probe`() = runTest {
        var now = 100L
        var shouldFail = true
        val runtime = ToolPluginRuntime(nowMillis = { now })
        runtime.register(plugin("unstable", failureThreshold = 2, circuitResetMillis = 50) {
            if (shouldFail) error("failed") else "recovered"
        })
        runtime.start("unstable")
        val call = ToolCall("1", "unstable", "{}")

        repeat(2) { assertFailsWith<IllegalStateException> { runtime.execute(call) } }
        assertEquals(ToolCircuitState.OPEN, runtime.status("unstable").circuit)
        val open = assertFailsWith<ToolPluginException> { runtime.execute(call) }
        assertEquals(ToolPluginErrorCode.CIRCUIT_OPEN, open.code)

        now += 50
        assertEquals(ToolCircuitState.HALF_OPEN, runtime.status("unstable").circuit)
        shouldFail = false
        assertEquals("recovered", runtime.execute(call))
        assertEquals(ToolCircuitState.CLOSED, runtime.status("unstable").circuit)
        assertEquals(0, runtime.status("unstable").consecutiveFailures)
    }

    @Test
    fun `manifest drives approval policy and validates configuration`() {
        val runtime = ToolPluginRuntime()
        runtime.register(plugin("read", requiresApproval = false))
        runtime.register(plugin("write", requiresApproval = true))
        val policy = runtime.approvalPolicy()

        assertFalse(policy.requiresApproval(ToolCall("1", "read", "{}")))
        assertTrue(policy.requiresApproval(ToolCall("2", "write", "{}")))
        assertTrue(policy.requiresApproval(ToolCall("3", "unknown", "{}")))
        assertFailsWith<IllegalArgumentException> {
            manifest("invalid", timeoutMillis = 0)
        }
    }

    private fun plugin(
        name: String,
        capability: String = "test.execute",
        timeoutMillis: Long = 1_000,
        maxOutputChars: Int = 1_000,
        failureThreshold: Int = 3,
        circuitResetMillis: Long = 30_000,
        requiresApproval: Boolean = false,
        events: MutableList<String> = mutableListOf(),
        handler: suspend (ToolCall) -> String = { "ok" },
    ) = object : ToolPlugin {
        override val manifest = manifest(
            name,
            capability,
            timeoutMillis,
            maxOutputChars,
            failureThreshold,
            circuitResetMillis,
            requiresApproval,
        )

        override suspend fun start() { events += "start" }
        override suspend fun stop() { events += "stop" }
        override suspend fun execute(call: ToolCall): String {
            events += "execute"
            return handler(call)
        }
    }

    private fun manifest(
        name: String,
        capability: String = "test.execute",
        timeoutMillis: Long = 1_000,
        maxOutputChars: Int = 1_000,
        failureThreshold: Int = 3,
        circuitResetMillis: Long = 30_000,
        requiresApproval: Boolean = false,
    ) = ToolPluginManifest(
        name = name,
        capability = capability,
        risk = ToolRisk.LOW,
        requiresApproval = requiresApproval,
        timeoutMillis = timeoutMillis,
        maxOutputChars = maxOutputChars,
        checkpointRequirement = CheckpointRequirement.NONE,
        failureThreshold = failureThreshold,
        circuitResetMillis = circuitResetMillis,
    )
}
