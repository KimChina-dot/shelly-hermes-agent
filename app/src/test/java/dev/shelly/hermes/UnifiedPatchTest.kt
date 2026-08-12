package dev.shelly.hermes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UnifiedPatchTest {
    @Test
    fun appliesMultipleHunksAndPreservesTrailingNewline() {
        val original = "alpha\nbeta\ngamma\ndelta\n"
        val patch = """
            --- a/sample.txt
            +++ b/sample.txt
            @@ -1,2 +1,2 @@
             alpha
            -beta
            +bravo
            @@ -3,2 +3,3 @@
             gamma
            +inserted
             delta
        """.trimIndent()

        val result = UnifiedPatch.apply(original, patch)

        assertEquals("alpha\nbravo\ngamma\ninserted\ndelta\n", result.text)
        assertEquals(2, result.hunksApplied)
    }

    @Test
    fun rejectsStaleContextWithoutProducingPartialOutput() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            UnifiedPatch.apply(
                "current value\n",
                """
                    @@ -1 +1 @@
                    -old value
                    +new value
                """.trimIndent(),
            )
        }

        assertEquals(true, error.message?.contains("stale"))
    }

    @Test
    fun rejectsIncorrectHunkCounts() {
        assertThrows(IllegalArgumentException::class.java) {
            UnifiedPatch.apply(
                "one\ntwo\n",
                """
                    @@ -1,2 +1,2 @@
                     one
                    -two
                """.trimIndent(),
            )
        }
    }

    @Test
    fun insertsAtZeroLineForEmptySource() {
        val result = UnifiedPatch.apply(
            "",
            """
                @@ -0,0 +1,2 @@
                +first
                +second
            """.trimIndent(),
        )

        assertEquals("first\nsecond", result.text)
    }
}
