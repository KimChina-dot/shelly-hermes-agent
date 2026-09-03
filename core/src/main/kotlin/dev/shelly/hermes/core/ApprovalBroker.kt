package dev.shelly.hermes.core

import java.util.concurrent.CompletableFuture
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * Platform-neutral implementation of [ApprovalGateway] that suspends the agent until a human
 * decision arrives via [resolve].
 *
 * The broker records the pending [ToolCall] so a host (Android activity, CLI prompt, ...) can
 * render it for the user. It deliberately depends only on the JDK so it can be unit tested
 * without a device and reused by every host.
 */
class ApprovalBroker : ApprovalGateway {

    /** Host callback invoked (on the requesting thread) whenever a tool call needs a decision. */
    var launcher: ((PendingApproval) -> Unit)? = null

    @Volatile
    private var pending: PendingApproval? = null

    override suspend fun request(call: ToolCall): ApprovalDecision {
        val born = PendingApproval(call)
        pending = born
        launcher?.invoke(born)
        return suspendCoroutine { continuation ->
            born.decision.whenComplete { value, error ->
                if (error != null) {
                    continuation.resumeWithException(error)
                } else if (value != null) {
                    continuation.resume(value)
                }
            }
        }
    }

    /**
     * Resolves the active pending request.
     *
     * @return true when a pending request was resolved; false when there was nothing pending
     *         (e.g. the user opened the approval screen without an active agent request).
     */
    fun resolve(decision: ApprovalDecision): Boolean {
        val current = pending ?: return false
        pending = null
        current.decision.complete(decision)
        return true
    }

    val active: PendingApproval? get() = pending
}

/** A tool call awaiting a human decision. */
class PendingApproval(
    val call: ToolCall,
    internal val decision: CompletableFuture<ApprovalDecision> = CompletableFuture()
)