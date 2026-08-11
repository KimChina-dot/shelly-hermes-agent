package dev.shelly.hermes.core

data class DiffHunk(
    val id: String,
    val filePath: String,
    val header: String,
    val lines: List<String>
)

enum class HunkDecision { PENDING, APPROVED, REJECTED }

data class DiffApprovalState(
    val decisions: Map<String, HunkDecision> = emptyMap()
) {
    fun decide(hunkId: String, decision: HunkDecision): DiffApprovalState =
        copy(decisions = decisions + (hunkId to decision))

    fun decisionFor(hunk: DiffHunk): HunkDecision = decisions[hunk.id] ?: HunkDecision.PENDING

    fun approved(hunks: List<DiffHunk>): List<DiffHunk> =
        hunks.filter { decisionFor(it) == HunkDecision.APPROVED }
}
