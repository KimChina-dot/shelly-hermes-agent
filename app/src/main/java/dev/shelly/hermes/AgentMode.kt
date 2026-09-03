package dev.shelly.hermes

/** User-selected safety boundary for one agent task. */
enum class AgentMode {
    PLAN,
    ACT;

    val wireValue: String get() = name.lowercase()

    companion object {
        fun fromWireValue(value: String?): AgentMode = entries.firstOrNull {
            it.wireValue.equals(value, ignoreCase = true)
        } ?: ACT
    }
}
