package dev.shelly.hermes.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiffHunkApprovalTest {
    @Test fun expandsApplyPatchIntoReviewableHunks() {
        val call = ToolCall(
            "patch-1",
            "apply_patch",
            "{\"path\":\"sample.txt\",\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\\n@@ -4 +4 @@\\n-before\\n+after\"}",
        )

        val hunks = DiffHunkApproval.expand(call)

        assertEquals(2, hunks.size)
        assertEquals("apply_patch_hunk", hunks[0].name)
        assertTrue(hunks[0].argumentsJson.contains("old"))
        assertTrue(hunks[1].argumentsJson.contains("before"))
    }

    @Test fun leavesOtherToolsUnchanged() {
        val call = ToolCall("read", "read_file", "{}")
        assertEquals(listOf(call), DiffHunkApproval.expand(call))
    }

    @Test fun collapsesOnlyApprovedHunksIntoApplyPatch() {
        val hunks = DiffHunkApproval.expand(
            ToolCall(
                "patch-1",
                "apply_patch",
                "{\"path\":\"sample.txt\",\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\\n@@ -4 +4 @@\\n-before\\n+after\"}",
            ),
        )

        val collapsed = DiffHunkApproval.collapse(listOf(hunks[1]))

        assertEquals("patch-1", collapsed.id)
        assertEquals("apply_patch", collapsed.name)
        assertTrue(collapsed.argumentsJson.contains("sample.txt"))
        assertTrue(collapsed.argumentsJson.contains("@@ -4 +4 @@"))
        assertFalse(collapsed.argumentsJson.contains("@@ -1 +1 @@"))
    }
}
