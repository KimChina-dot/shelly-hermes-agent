package dev.shelly.hermes

import dev.shelly.hermes.core.CheckpointRequirement
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolPluginErrorCode
import dev.shelly.hermes.core.ToolPluginException
import dev.shelly.hermes.core.ToolPluginManifest
import dev.shelly.hermes.core.ToolPluginRuntime
import dev.shelly.hermes.core.ToolRisk
import dev.shelly.hermes.core.AgentProfiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

class AndroidWorkspaceToolPluginsTest {
    @Test fun catalogDeclaresEveryWorkspaceToolExactlyOnce() {
        val manifests = AndroidWorkspaceToolPlugins.manifests
        assertEquals(
            listOf(
                "read_file", "exists", "list_files", "search_files",
                "apply_patch", "create_file", "overwrite_file", "append_file",
            ),
            manifests.map { it.name },
        )
        assertEquals(manifests.size, manifests.map { it.capability }.toSet().size)
        assertTrue(manifests.all { it.timeoutMillis > 0 && it.maxOutputChars > 0 })
        assertTrue(manifests.all { it.failureThreshold > 0 && it.circuitResetMillis > 0 })
    }

    @Test fun readToolsAreLowRiskAndWritesRequireApprovalAndCheckpoint() {
        val byName = AndroidWorkspaceToolPlugins.manifests.associateBy { it.name }
        setOf("read_file", "exists", "list_files", "search_files").forEach { name ->
            val manifest = byName.getValue(name)
            assertEquals(ToolRisk.LOW, manifest.risk)
            assertFalse(manifest.requiresApproval)
            assertEquals(CheckpointRequirement.NONE, manifest.checkpointRequirement)
        }
        setOf("apply_patch", "create_file", "overwrite_file", "append_file").forEach { name ->
            val manifest = byName.getValue(name)
            assertTrue(manifest.risk == ToolRisk.MEDIUM || manifest.risk == ToolRisk.HIGH)
            assertTrue(manifest.requiresApproval)
            assertEquals(CheckpointRequirement.REQUIRED, manifest.checkpointRequirement)
        }
    }

    @Test fun modelDefinitionsCannotExposeToolsOutsideThePluginCatalog() {
        val catalogNames = AndroidWorkspaceToolPlugins.manifests.mapTo(linkedSetOf<String>()) { it.name }
        assertEquals(catalogNames, OpenAiAgentModelGateway.toolDefinitionNames(AgentMode.ACT))
        assertEquals(
            setOf("read_file", "exists", "list_files", "search_files"),
            OpenAiAgentModelGateway.toolDefinitionNames(AgentMode.PLAN),
        )
    }

    @Test fun builtInProfilesCannotGrantUndeclaredAndroidToolsOrCapabilities() {
        val byName = AndroidWorkspaceToolPlugins.manifests.associateBy { it.name }
        AgentProfiles.builtIns.forEach { profile ->
            assertTrue(profile.toolNames.all(byName::containsKey))
            assertTrue(profile.toolNames.map { byName.getValue(it).capability }.toSet()
                .containsAll(profile.allowedCapabilities))
        }
    }

    @Test fun runtimeRejectsUnknownToolsAndTruncatesPluginOutput() {
        val manifest = ToolPluginManifest(
            name = "bounded",
            capability = "test.bounded",
            risk = ToolRisk.LOW,
            requiresApproval = false,
            timeoutMillis = 1_000,
            maxOutputChars = 20,
            checkpointRequirement = CheckpointRequirement.NONE,
            failureThreshold = 2,
            circuitResetMillis = 1_000,
        )
        val runtime = ToolPluginRuntime()
        runtime.register(AndroidWorkspaceToolPlugins.plugin(manifest) { "abcdefghijklmnopqrstuvwxyz" })
        runSuspend { runtime.startAll() }

        val unknown = assertThrows(ToolPluginException::class.java) {
            runSuspend { runtime.execute(ToolCall("1", "unknown", "{}")) }
        }
        assertEquals(ToolPluginErrorCode.NOT_REGISTERED, unknown.code)
        val output = runSuspend { runtime.execute(ToolCall("2", "bounded", "{}")) }
        assertEquals(20, output.length)
        assertTrue(output.endsWith("...[truncated]"))
    }

    private fun <T> runSuspend(block: suspend () -> T): T {
        val latch = CountDownLatch(1)
        var outcome: Result<T>? = null
        block.startCoroutine(object : Continuation<T> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(result: Result<T>) {
                outcome = result
                latch.countDown()
            }
        })
        check(latch.await(5, TimeUnit.SECONDS)) { "Suspend test timed out" }
        return outcome!!.getOrThrow()
    }
}
