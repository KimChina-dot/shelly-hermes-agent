package dev.shelly.hermes

import dev.shelly.hermes.core.ApprovalBroker
import dev.shelly.hermes.core.ApprovalDecision
import dev.shelly.hermes.core.ApprovalGateway
import dev.shelly.hermes.core.PendingApproval
import dev.shelly.hermes.core.ToolCall

/**
 * Android adapter over the platform-neutral [ApprovalBroker].
 *
 * The broker keeps the agent suspended while a tool call awaits a human decision; this adapter
 * only exposes the broker to the Android UI layer (see [ApprovalActivity]).
 */
class AndroidApprovalGateway : ApprovalGateway {

    private val broker = ApprovalBroker()

    /** Invoked when a tool call needs a decision. Wire this to launch [ApprovalActivity]. */
    var launcher: ((PendingApproval) -> Unit)?
        get() = broker.launcher
        set(value) { broker.launcher = value }

    override suspend fun request(call: ToolCall): ApprovalDecision = broker.request(call)

    fun resolve(decision: ApprovalDecision): Boolean = broker.resolve(decision)

    val active: PendingApproval? get() = broker.active
}