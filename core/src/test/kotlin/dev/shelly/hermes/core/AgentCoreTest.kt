package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

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
}
