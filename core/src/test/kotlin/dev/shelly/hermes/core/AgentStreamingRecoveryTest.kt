package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class AgentStreamingRecoveryTest {
    @Test
    fun `streams model deltas before final reply`() = runTest {
        val events = mutableListOf<AgentEvent>()
        val core = AgentCore(
            model = StreamingFake(listOf("He", "llo"), complete = ModelReply(content = "Hello")),
            tools = ToolExecutor { "" },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { },
            observer = AgentObserver { events += it },
        )

        val result = core.run(emptyList(), neverCancelled())

        assertEquals("Hello", assertIs<AgentResult.Completed>(result).message)
        assertEquals(listOf("He", "llo"), events.filterIsInstance<AgentEvent.ModelDelta>().map { it.text })
    }

    @Test
    fun `resumes an approved tool without calling the model first`() = runTest {
        var modelCalls = 0
        val executed = mutableListOf<ToolCall>()
        val call = ToolCall("write-1", "overwrite_file", "{\"path\":\"a.txt\",\"content\":\"ok\"}")
        val checkpoint = AgentCheckpoint(
            messages = listOf(AgentMessage(MessageRole.ASSISTANT, "", toolCalls = listOf(call))),
            round = 1,
            consumedTokens = 10,
            toolCalls = 1,
            pendingToolCalls = listOf(PendingToolCall(call, ToolExecutionStage.AWAITING_EXECUTION)),
        )
        val core = AgentCore(
            model = ModelGateway {
                modelCalls += 1
                ModelReply(content = "done")
            },
            tools = ToolExecutor { executed += it; "written" },
            approvals = ApprovalGateway { error("already approved before process death") },
            checkpoints = CheckpointStore { },
        )

        val result = core.run(emptyList(), neverCancelled(), checkpoint)

        assertIs<AgentResult.Completed>(result)
        assertEquals(1, modelCalls)
        assertEquals(listOf(call), executed)
        assertEquals(MessageRole.ASSISTANT, result.checkpoint.messages.last().role)
        assertTrue(
            result.checkpoint.messages.any {
                it.role == MessageRole.TOOL && it.toolCallId == call.id
            },
        )
        assertTrue(result.checkpoint.pendingToolCalls.isEmpty())
    }

    @Test
    fun `partial hunk approval executes only accepted hunks`() = runTest {
        var modelCalls = 0
        val executed = mutableListOf<ToolCall>()
        val approvals = ArrayDeque(listOf(ApprovalDecision.APPROVE, ApprovalDecision.REJECT))
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) {
                    ModelReply(
                        toolCalls = listOf(
                            ToolCall(
                                "patch-1",
                                "apply_patch",
                                "{\"path\":\"sample.txt\",\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\\n@@ -4 +4 @@\\n-before\\n+after\"}",
                            ),
                        ),
                    )
                } else {
                    ModelReply(content = "done")
                }
            },
            tools = ToolExecutor { executed += it; "patched" },
            approvals = ApprovalGateway { approvals.removeFirst() },
            checkpoints = CheckpointStore { },
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))

        val patch = executed.single()
        assertEquals("apply_patch", patch.name)
        assertTrue(patch.argumentsJson.contains("+new"))
        assertTrue(!patch.argumentsJson.contains("+after"))
    }

    private class StreamingFake(
        private val deltas: List<String>,
        private val complete: ModelReply,
    ) : ModelGateway, StreamingModelGateway {
        override suspend fun complete(messages: List<AgentMessage>): ModelReply = complete

        override suspend fun completeStreaming(
            messages: List<AgentMessage>,
            onDelta: (String) -> Unit,
        ): ModelReply {
            deltas.forEach(onDelta)
            return complete
        }
    }

    private fun neverCancelled() = object : CancellationSignal {
        override val isCancelled = false
    }
}
