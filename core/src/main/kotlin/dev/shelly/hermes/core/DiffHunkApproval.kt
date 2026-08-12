package dev.shelly.hermes.core

/** Splits a unified patch into independently reviewable hunks without applying them. */
object DiffHunkApproval {
    fun expand(call: ToolCall): List<ToolCall> {
        if (call.name != "apply_patch") return listOf(call)
        val path = jsonString(call.argumentsJson, "path") ?: return listOf(call)
        val patch = jsonString(call.argumentsJson, "patch") ?: return listOf(call)
        val lines = patch.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val headers = lines.mapIndexedNotNull { index, line -> index.takeIf { line.startsWith("@@ ") } }
        if (headers.isEmpty()) return listOf(call)
        return headers.mapIndexed { index, start ->
            val end = headers.getOrNull(index + 1) ?: lines.size
            val hunk = lines.subList(start, end).joinToString("\n").trimEnd()
            ToolCall(
                id = "${call.id}:hunk-${index + 1}",
                name = "apply_patch_hunk",
                argumentsJson = "{\"path\":\"${escape(path)}\",\"hunk_index\":${index + 1}," +
                    "\"hunk_count\":${headers.size},\"hunk\":\"${escape(hunk)}\"}",
            )
        }
    }

    private fun jsonString(json: String, key: String): String? {
        val match = Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"").find(json)
            ?: return null
        return Regex("\\\\(?:[\\\"\\\\/bfnrt]|u[0-9a-fA-F]{4})").replace(match.groupValues[1]) { escaped ->
            when (val token = escaped.value.drop(1)) {
                "\"" -> "\""; "\\" -> "\\"; "/" -> "/"; "b" -> "\b"; "f" -> "\u000c"
                "n" -> "\n"; "r" -> "\r"; "t" -> "\t"
                else -> token.drop(1).toInt(16).toChar().toString()
            }
        }
    }

    private fun escape(value: String): String = buildString {
        value.forEach { character ->
            append(when (character) {
                '\\' -> "\\\\"; '\"' -> "\\\""; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"
                else -> character
            })
        }
    }
}
