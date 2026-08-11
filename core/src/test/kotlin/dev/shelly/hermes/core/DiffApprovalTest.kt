package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiffApprovalTest {

    private val hunkA = DiffHunk("a", "src/A.kt", "@@ -1 +1 @@", listOf("-old", "+new"))
    private val hunkB = DiffHunk("b", "src/B.kt", "@@ -5 +5 @@", listOf("-x", "+y"))

    @Test
    fun `incomplete until every hunk decided`() {
        val state = DiffApprovalState()
        assertFalse(state.isComplete(listOf(hunkA, hunkB)))

        val partial = state.decide("a", HunkDecision.APPROVED)
        assertFalse(partial.isComplete(listOf(hunkA, hunkB)))

        val full = partial.decide("b", HunkDecision.REJECTED)
        assertTrue(full.isComplete(listOf(hunkA, hunkB)))
    }

    @Test
    fun `approved filters only approved hunks`() {
        val state = DiffApprovalState()
            .decide("a", HunkDecision.APPROVED)
            .decide("b", HunkDecision.REJECTED)
        assertEquals(listOf(hunkA), state.approved(listOf(hunkA, hunkB)))
    }

    @Test
    fun `render includes approved hunks only`() {
        val state = DiffApprovalState()
            .decide("a", HunkDecision.APPROVED)
            .decide("b", HunkDecision.REJECTED)
        val rendered = state.renderApproved(listOf(hunkA, hunkB))
        assertTrue(rendered.contains("src/A.kt"))
        assertTrue(rendered.contains("+new"))
        assertFalse(rendered.contains("src/B.kt"))
    }

    @Test
    fun `bundle round-trips decisions`() {
        val state = DiffApprovalState()
            .decide("a", HunkDecision.APPROVED)
            .decide("b", HunkDecision.REJECTED)
        val bundle = state.toBundlePrefixed("d_")
        val restored = DiffApprovalState.fromBundlePrefixed("d_", bundle)
        assertEquals(HunkDecision.APPROVED, restored.decisionFor(hunkA))
        assertEquals(HunkDecision.REJECTED, restored.decisionFor(hunkB))
    }
}