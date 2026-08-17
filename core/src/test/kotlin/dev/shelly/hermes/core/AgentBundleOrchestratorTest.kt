package dev.shelly.hermes.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class AgentBundleOrchestratorTest {
    @Test fun `runs planner coding reviewer with handoff context`() = runTest {
        val calls = mutableListOf<Pair<String, List<AgentMessage>>>()
        val transitions = mutableListOf<AgentCheckpoint>()
        val orchestrator = AgentBundleOrchestrator(
            runner = AgentProfileRunner { profile, messages, _, _ ->
                calls += profile.id to messages
                completed(messages, "${profile.id}-output")
            },
            checkpoints = CheckpointStore { transitions += it },
        )

        val result = assertIs<AgentResult.Completed>(
            orchestrator.run(
                AgentProfiles.STANDARD_BUNDLE,
                listOf(AgentMessage(MessageRole.USER, "build it")),
                neverCancelled(),
            ),
        )

        assertEquals(listOf("planner", "coding", "reviewer"), calls.map { it.first })
        assertTrue(calls[1].second.any { it.content.contains("planner-output") })
        assertTrue(calls[2].second.any { it.content.contains("coding-output") })
        assertTrue(result.message.contains("coding-output"))
        assertTrue(result.message.contains("reviewer-output"))
        assertEquals(2, transitions.size)
        assertTrue(transitions.last().messages.any { it.content == AgentBundleOrchestrator.roleMarker("reviewer") })
    }

    @Test fun `resumes from role marker without rerunning prior roles`() = runTest {
        val calls = mutableListOf<String>()
        val checkpoint = AgentCheckpoint(
            messages = listOf(
                AgentMessage(MessageRole.USER, "build"),
                AgentMessage(MessageRole.SYSTEM, AgentBundleOrchestrator.roleMarker("coding")),
            ),
            round = 2,
            consumedTokens = 10,
            toolCalls = 1,
        )
        val orchestrator = AgentBundleOrchestrator(AgentProfileRunner { profile, messages, _, resume ->
            calls += profile.id
            assertTrue(profile.id != "coding" || resume === checkpoint)
            completed(if (resume != null) resume.messages else messages, "${profile.id}-done")
        })

        assertIs<AgentResult.Completed>(
            orchestrator.run(AgentProfiles.STANDARD_BUNDLE, emptyList(), neverCancelled(), checkpoint),
        )
        assertEquals(listOf("coding", "reviewer"), calls)
    }

    @Test fun `propagates stopped role and does not run later phases`() = runTest {
        val calls = mutableListOf<String>()
        val orchestrator = AgentBundleOrchestrator(AgentProfileRunner { profile, messages, _, _ ->
            calls += profile.id
            val checkpoint = AgentCheckpoint(messages, 0, 0, 0)
            if (profile.id == "coding") AgentResult.Stopped("budget", checkpoint)
            else AgentResult.Completed("plan", checkpoint)
        })

        val result = assertIs<AgentResult.Stopped>(
            orchestrator.run(
                AgentProfiles.STANDARD_BUNDLE,
                listOf(AgentMessage(MessageRole.USER, "build")),
                neverCancelled(),
            ),
        )
        assertEquals("budget", result.reason)
        assertEquals(listOf("planner", "coding"), calls)
    }

    private fun completed(messages: List<AgentMessage>, output: String): AgentResult.Completed {
        val all = messages + AgentMessage(MessageRole.ASSISTANT, output)
        return AgentResult.Completed(output, AgentCheckpoint(all, 1, 1, 0))
    }

    private fun neverCancelled() = object : CancellationSignal {
        override val isCancelled = false
    }
}
