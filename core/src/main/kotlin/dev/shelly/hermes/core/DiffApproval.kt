package dev.shelly.hermes.core

data class DiffHunk(
    val id: String,
    val filePath: String,
    val header: String,
    val lines: List<String>
) {
    /** Renders the hunk as a unified-diff style block for display. */
    fun render(): String = buildString {
        append("--- ").append(filePath).append('\n')
        append("+++ ").append(filePath).append('\n')
        append(header).append('\n')
        lines.forEach { append(it).append('\n') }
    }
}

enum class HunkDecision { PENDING, APPROVED, REJECTED }

data class DiffApprovalState(
    val decisions: Map<String, HunkDecision> = emptyMap()
) {
    fun decide(hunkId: String, decision: HunkDecision): DiffApprovalState =
        copy(decisions = decisions + (hunkId to decision))

    fun decisionFor(hunk: DiffHunk): HunkDecision = decisions[hunk.id] ?: HunkDecision.PENDING

    fun approved(hunks: List<DiffHunk>): List<DiffHunk> =
        hunks.filter { decisionFor(it) == HunkDecision.APPROVED }

    /** True when every hunk has a non-pending decision. */
    fun isComplete(hunks: List<DiffHunk>): Boolean =
        hunks.isNotEmpty() && hunks.all { decisionFor(it) != HunkDecision.PENDING }

    /** Renders the full diff keeping only lines from approved hunks. */
    fun renderApproved(hunks: List<DiffHunk>): String =
        approved(hunks).joinToString(separator = "\n") { it.render() }

    fun toBundlePrefixed(prefix: String): Map<String, String> =
        decisions.mapKeys { (key, _) -> "$prefix$key" }.mapValues { (_, value) -> value.name }

    companion object {
        fun fromBundlePrefixed(prefix: String, values: Map<String, String>): DiffApprovalState {
            val decisions = values
                .filterKeys { it.startsWith(prefix) }
                .mapKeys { (key, _) -> key.removePrefix(prefix) }
                .mapNotNull { (key, value) ->
                    HunkDecision.entries.firstOrNull { it.name == value }?.let { key to it }
                }
                .toMap()
            return DiffApprovalState(decisions)
        }
    }
}