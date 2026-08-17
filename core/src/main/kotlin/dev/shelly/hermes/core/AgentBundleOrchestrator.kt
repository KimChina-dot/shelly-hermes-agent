package dev.shelly.hermes.core

fun interface AgentProfileRunner {
    suspend fun run(
        profile: AgentProfile,
        messages: List<AgentMessage>,
        cancellation: CancellationSignal,
        resumeFrom: AgentCheckpoint?,
    ): AgentResult
}

/** Sequential Planner -> Coding -> Reviewer handoff with checkpoint-aware phase resume. */
class AgentBundleOrchestrator(
    private val runner: AgentProfileRunner,
    private val checkpoints: CheckpointStore? = null,
) {
    suspend fun run(
        bundle: AgentBundle,
        initialMessages: List<AgentMessage>,
        cancellation: CancellationSignal,
        resumeFrom: AgentCheckpoint? = null,
    ): AgentResult {
        val ordered = executionOrder(bundle)
        val resumedProfileId = resumeFrom?.messages
            ?.lastOrNull { it.role == MessageRole.SYSTEM && it.content.startsWith(ROLE_MARKER_PREFIX) }
            ?.content
            ?.removePrefix(ROLE_MARKER_PREFIX)
            ?.removeSuffix("]")
        val startIndex = resumedProfileId?.let { id -> ordered.indexOfFirst { it.id == id } }
            ?.takeIf { it >= 0 }
            ?: 0
        var sharedMessages = if (resumeFrom == null) initialMessages else resumeFrom.messages
        var phaseResume = resumeFrom
        var latestCheckpoint = resumeFrom ?: AgentCheckpoint(initialMessages, 0, 0, 0)
        val outputs = linkedMapOf<String, String>().apply {
            resumeFrom?.messages?.forEach { message ->
                if (message.role == MessageRole.SYSTEM && message.content.startsWith(PLANNER_HANDOFF)) {
                    put(AgentProfiles.PLANNER.id, message.content.removePrefix(PLANNER_HANDOFF))
                }
                if (message.role == MessageRole.SYSTEM && message.content.startsWith(CODING_HANDOFF)) {
                    put(AgentProfiles.CODING.id, message.content.removePrefix(CODING_HANDOFF))
                }
            }
        }

        for (index in startIndex until ordered.size) {
            if (cancellation.isCancelled) return AgentResult.Stopped("cancelled", latestCheckpoint)
            val profile = ordered[index]
            val phaseMessages = if (phaseResume != null) {
                emptyList()
            } else {
                buildPhaseMessages(initialMessages, outputs, profile)
            }
            when (val result = runner.run(profile, phaseMessages, cancellation, phaseResume)) {
                is AgentResult.Stopped -> return result
                is AgentResult.Completed -> {
                    outputs[profile.id] = result.message
                    latestCheckpoint = result.checkpoint
                    sharedMessages = result.checkpoint.messages
                    if (index < ordered.lastIndex) {
                        val transition = AgentCheckpoint(
                            messages = buildPhaseMessages(initialMessages, outputs, ordered[index + 1]),
                            round = 0,
                            consumedTokens = 0,
                            toolCalls = 0,
                        )
                        checkpoints?.save(transition)
                        latestCheckpoint = transition
                    }
                }
            }
            phaseResume = null
        }

        val coding = outputs[AgentProfiles.CODING.id].orEmpty()
        val review = outputs[AgentProfiles.REVIEWER.id].orEmpty()
        val finalMessage = buildString {
            append(coding.ifBlank { sharedMessages.lastOrNull { it.role == MessageRole.ASSISTANT }?.content.orEmpty() })
            if (review.isNotBlank()) {
                if (isNotEmpty()) append("\n\n")
                append("Review:\n")
                append(review)
            }
        }
        return AgentResult.Completed(finalMessage, latestCheckpoint)
    }

    private fun buildPhaseMessages(
        initialMessages: List<AgentMessage>,
        outputs: Map<String, String>,
        profile: AgentProfile,
    ): List<AgentMessage> = buildList {
        addAll(initialMessages.filterNot { it.role == MessageRole.SYSTEM && it.content.startsWith(ROLE_MARKER_PREFIX) })
        outputs[AgentProfiles.PLANNER.id]?.takeIf { it.isNotBlank() }?.let {
            add(AgentMessage(MessageRole.SYSTEM, PLANNER_HANDOFF + it))
        }
        outputs[AgentProfiles.CODING.id]?.takeIf { it.isNotBlank() }?.let {
            add(AgentMessage(MessageRole.SYSTEM, CODING_HANDOFF + it))
        }
        add(AgentMessage(MessageRole.SYSTEM, roleMarker(profile.id)))
        add(AgentMessage(MessageRole.SYSTEM, profile.systemPrompt))
    }

    private fun executionOrder(bundle: AgentBundle): List<AgentProfile> {
        val preferred = listOf(AgentProfiles.PLANNER.id, AgentProfiles.CODING.id, AgentProfiles.REVIEWER.id)
        return bundle.profiles.sortedBy { profile ->
            preferred.indexOf(profile.id).takeIf { it >= 0 } ?: preferred.size
        }
    }

    companion object {
        const val ROLE_MARKER_PREFIX = "[LUMA_ROLE:"
        private const val PLANNER_HANDOFF = "Planner handoff:\n"
        private const val CODING_HANDOFF = "Coding handoff:\n"

        fun roleMarker(profileId: String): String = "$ROLE_MARKER_PREFIX$profileId]"
    }
}
