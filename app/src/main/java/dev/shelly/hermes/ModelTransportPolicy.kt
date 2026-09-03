package dev.shelly.hermes

/** Pure retry policy shared by buffered and streaming model requests. */
data class ModelRetryPolicy(
    val maxRetries: Int = 2,
    val initialDelayMs: Long = 500,
    val maxDelayMs: Long = 4_000,
) {
    init {
        require(maxRetries >= 0) { "maxRetries must not be negative" }
        require(initialDelayMs >= 0) { "initialDelayMs must not be negative" }
        require(maxDelayMs >= initialDelayMs) { "maxDelayMs must be at least initialDelayMs" }
    }

    fun delayBeforeRetry(retryIndex: Int): Long {
        require(retryIndex >= 0) { "retryIndex must not be negative" }
        var delay = initialDelayMs
        repeat(retryIndex) {
            delay = (delay * 2).coerceAtMost(maxDelayMs)
        }
        return delay
    }

    fun isRetryableStatus(status: Int): Boolean = status == 429 || status in 500..599

    fun isRetryableFailure(error: Throwable): Boolean = when (error) {
        is ModelGatewayException.RateLimited,
        is ModelGatewayException.Network,
        -> true
        is ModelGatewayException.Timeout -> error.httpStatus == null ||
            error.httpStatus?.let(::isRetryableStatus) == true
        is ModelGatewayException.Upstream -> error.httpStatus?.let(::isRetryableStatus) == true
        else -> false
    }
}

/**
 * Minimal SSE decoder. It accepts lines without their line terminator and dispatches an event on
 * a blank line. Multiple `data:` fields are joined with a newline as required by the SSE format.
 */
internal class SseEventParser(
    private val onEvent: (SseEvent) -> Unit,
) {
    private val dataLines = mutableListOf<String>()
    private var eventName: String? = null
    private var eventId: String? = null

    fun acceptLine(line: String) {
        if (line.isEmpty()) {
            dispatch()
            return
        }
        if (line.startsWith(':')) return

        val separator = line.indexOf(':')
        val field = if (separator < 0) line else line.substring(0, separator)
        val rawValue = if (separator < 0) "" else line.substring(separator + 1)
        val value = rawValue.removePrefix(" ")
        when (field) {
            "data" -> dataLines += value
            "event" -> eventName = value
            "id" -> if ('\u0000' !in value) eventId = value
        }
    }

    fun finish() = dispatch()

    private fun dispatch() {
        if (dataLines.isEmpty()) {
            eventName = null
            return
        }
        val data = dataLines.joinToString("\n")
        val event = SseEvent(data, eventName, eventId, data == "[DONE]")
        dataLines.clear()
        eventName = null
        onEvent(event)
    }
}

data class SseEvent(
    val data: String,
    val event: String? = null,
    val id: String? = null,
    val isDone: Boolean = false,
)
