package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class AgentCoreTest {
    @Test
    fun `executes approved tool then completes`() = kotlinx.coroutines.test.runTest {
        var calls = 0
        val saved = mutableListOf<AgentCheckpoint>()
        val core = AgentCore(
            model = ModelGateway {
                if (calls++ == 0) ModelReply(toolCalls = listOf(ToolCall("1", "read_file", "{}")))
                else ModelReply(content = "完成")
            },
            tools = ToolExecutor { "content" },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { saved += it }
        )
        val result = core.run(listOf(AgentMessage(MessageRole.USER, "检查项目")), object : CancellationSignal {
            override val isCancelled = false
        })
        assertIs<AgentResult.Completed>(result)
        assertEquals("完成", result.message)
        assertEquals(1, result.checkpoint.toolCalls)
    }

    @Test
    fun `stops before model call when cancelled`() = kotlinx.coroutines.test.runTest {
        val core = AgentCore(
            model = ModelGateway { error("must not run") },
            tools = ToolExecutor { "" },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { }
        )
        val result = core.run(emptyList(), object : CancellationSignal {
            override val isCancelled = true
        })
        assertEquals("cancelled", assertIs<AgentResult.Stopped>(result).reason)
    }

    @Test
    fun `default policy still requests approval for read only tools`() = kotlinx.coroutines.test.runTest {
        var modelCalls = 0
        var approvalCalls = 0
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) ModelReply(toolCalls = listOf(ToolCall("read-1", "read_file", "{}")))
                else ModelReply(content = "done")
            },
            tools = ToolExecutor { "content" },
            approvals = ApprovalGateway {
                approvalCalls += 1
                ApprovalDecision.APPROVE
            },
            checkpoints = CheckpointStore { }
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals(1, approvalCalls)
    }

    @Test
    fun `read only policy skips approval round trip`() = kotlinx.coroutines.test.runTest {
        var modelCalls = 0
        val executed = mutableListOf<String>()
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) {
                    ModelReply(toolCalls = listOf(
                        ToolCall("read-1", "read_file", "{}"),
                        ToolCall("exists-1", "exists", "{}")
                    ))
                } else ModelReply(content = "done")
            },
            tools = ToolExecutor { call -> executed += call.name; "ok" },
            approvals = ApprovalGateway { error("read-only tools must not wait for approval") },
            checkpoints = CheckpointStore { },
            approvalPolicy = ToolApprovalPolicy.autoApproveReadOnly()
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals(listOf("read_file", "exists"), executed)
    }

    @Test
    fun `read only policy continues to require approval for mutations`() = kotlinx.coroutines.test.runTest {
        var modelCalls = 0
        var approvalCalls = 0
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) ModelReply(toolCalls = listOf(ToolCall("write-1", "overwrite_file", "{}")))
                else ModelReply(content = "done")
            },
            tools = ToolExecutor { "written" },
            approvals = ApprovalGateway {
                approvalCalls += 1
                ApprovalDecision.APPROVE
            },
            checkpoints = CheckpointStore { },
            approvalPolicy = ToolApprovalPolicy.autoApproveReadOnly()
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals(1, approvalCalls)
    }

    @Test
    fun `broken approval policy fails closed`() = kotlinx.coroutines.test.runTest {
        var modelCalls = 0
        var approvalCalls = 0
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) ModelReply(toolCalls = listOf(ToolCall("read-1", "read_file", "{}")))
                else ModelReply(content = "done")
            },
            tools = ToolExecutor { "content" },
            approvals = ApprovalGateway {
                approvalCalls += 1
                ApprovalDecision.APPROVE
            },
            checkpoints = CheckpointStore { },
            approvalPolicy = ToolApprovalPolicy { error("invalid policy state") }
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals(1, approvalCalls)
    }

    @Test
    fun `observer reports model approval and tool lifecycle with durations`() = kotlinx.coroutines.test.runTest {
        var modelCalls = 0
        var clock = 0L
        val events = mutableListOf<AgentEvent>()
        val core = AgentCore(
            model = ModelGateway {
                if (modelCalls++ == 0) ModelReply(toolCalls = listOf(ToolCall("write-1", "overwrite_file", "{}")))
                else ModelReply(content = "done")
            },
            tools = ToolExecutor { "written" },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { },
            observer = AgentObserver { events += it },
            nanoTime = { clock.also { clock += 2_000_000L } }
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))

        assertEquals(AgentEvent.ModelStarted(1), events[0])
        assertEquals(2L, assertIs<AgentEvent.ModelFinished>(events[1]).durationMillis)
        assertIs<AgentEvent.ApprovalWaiting>(events[2])
        assertEquals(2L, assertIs<AgentEvent.ApprovalFinished>(events[3]).durationMillis)
        val toolStarted = assertIs<AgentEvent.ToolStarted>(events[4])
        assertEquals("overwrite_file", toolStarted.toolName)
        val toolFinished = assertIs<AgentEvent.ToolFinished>(events[5])
        assertEquals("overwrite_file", toolFinished.toolName)
        assertEquals(2L, toolFinished.durationMillis)
        assertTrue(toolFinished.succeeded)
        assertIs<AgentEvent.ModelStarted>(events[6])
        assertIs<AgentEvent.ModelFinished>(events[7])
    }

    @Test
    fun `streaming gateway emits model deltas before final reply`() = kotlinx.coroutines.test.runTest {
        val events = mutableListOf<AgentEvent>()
        val core = AgentCore(
            model = StreamingGateway(listOf("Hello ", "world")),
            tools = ToolExecutor { "unused" },
            approvals = ApprovalGateway { error("no tools requested") },
            checkpoints = CheckpointStore { },
            observer = AgentObserver { events += it },
        )

        val result = assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals("Hello world", result.message)
        val deltaTexts = events.filterIsInstance<AgentEvent.ModelDelta>().map(AgentEvent.ModelDelta::text)
        assertEquals(listOf("Hello ", "world"), deltaTexts)
    }

    @Test
    fun `failed tool still emits completion event`() = kotlinx.coroutines.test.runTest {
        val events = mutableListOf<AgentEvent>()
        val core = AgentCore(
            model = ModelGateway { ModelReply(toolCalls = listOf(ToolCall("bad-1", "overwrite_file", "{}"))) },
            tools = ToolExecutor { error("disk failed") },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { },
            observer = AgentObserver { events += it }
        )

        val failure = runCatching { core.run(emptyList(), neverCancelled()) }
        assertTrue(failure.isFailure)
        val finished = assertIs<AgentEvent.ToolFinished>(events.last())
        assertFalse(finished.succeeded)
        assertEquals("overwrite_file", finished.toolName)
    }

    @Test
    fun `observer failure does not interrupt execution`() = kotlinx.coroutines.test.runTest {
        val core = AgentCore(
            model = ModelGateway { ModelReply(content = "done") },
            tools = ToolExecutor { "unused" },
            approvals = ApprovalGateway { ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { },
            observer = AgentObserver { error("telemetry failure") }
        )

        val result = assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled()))
        assertEquals("done", result.message)
    }

    @Test
    fun `resume approved but unstarted tool call does not prompt again`() = kotlinx.coroutines.test.runTest {
        var approvalCalls = 0
        val executed = mutableListOf<String>()
        val core = AgentCore(
            model = ModelGateway { ModelReply(content = "done") },
            tools = ToolExecutor { call -> executed += call.name; "written" },
            approvals = ApprovalGateway { approvalCalls += 1; ApprovalDecision.APPROVE },
            checkpoints = CheckpointStore { },
        )
        val checkpoint = AgentCheckpoint(
            messages = listOf(AgentMessage(MessageRole.ASSISTANT, "", toolCalls = listOf(ToolCall("write-1", "overwrite_file", "{}")))),
            round = 1,
            consumedTokens = 0,
            toolCalls = 1,
            pendingToolCalls = listOf(PendingToolCall(ToolCall("write-1", "overwrite_file", "{}"), ToolExecutionStage.AWAITING_EXECUTION)),
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled(), checkpoint))
        assertEquals(0, approvalCalls)
        assertEquals(listOf("overwrite_file"), executed)
    }

    @Test
    fun `resume interrupted running mutation asks user before retry`() = kotlinx.coroutines.test.runTest {
        var approvalCalls = 0
        val executed = mutableListOf<String>()
        val core = AgentCore(
            model = ModelGateway { ModelReply(content = "done") },
            tools = ToolExecutor { call -> executed += call.name; "written again" },
            approvals = ApprovalGateway {
                approvalCalls += 1
                ApprovalDecision.APPROVE
            },
            checkpoints = CheckpointStore { },
        )
        val checkpoint = AgentCheckpoint(
            messages = emptyList(),
            round = 1,
            consumedTokens = 0,
            toolCalls = 1,
            pendingToolCalls = listOf(PendingToolCall(ToolCall("write-1", "overwrite_file", "{}"), ToolExecutionStage.RUNNING)),
        )

        assertIs<AgentResult.Completed>(core.run(emptyList(), neverCancelled(), checkpoint))
        assertEquals(1, approvalCalls)
        assertEquals(listOf("overwrite_file"), executed)
    }

    private fun neverCancelled() = object : CancellationSignal {
        override val isCancelled = false
    }

    private class StreamingGateway(
        private val chunks: List<String>,
    ) : ModelGateway, StreamingModelGateway {
        override suspend fun complete(messages: List<AgentMessage>): ModelReply =
            ModelReply(content = chunks.joinToString(""))

        override suspend fun completeStreaming(
            messages: List<AgentMessage>,
            onDelta: (String) -> Unit,
        ): ModelReply {
            chunks.forEach(onDelta)
            return ModelReply(content = chunks.joinToString(""))
        }
    }
}
