package dev.shelly.hermes

import android.os.NetworkOnMainThreadException
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

/**
 * Android model gateway for OpenAI-compatible chat completion endpoints.
 *
 * The gateway deliberately relies only on Android/JDK networking APIs so it does not add a
 * project-wide dependency. Call [chatCompletions] from a background thread.
 */
class OpenAiModelGateway(
    private val configStore: ModelConfigStore,
    private val connectTimeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS,
    private val readTimeoutMs: Int = DEFAULT_READ_TIMEOUT_MS,
    private val retryPolicy: ModelRetryPolicy = ModelRetryPolicy(),
) {
    private val activeRequest = AtomicReference<ActiveRequest?>()
    init {
        require(connectTimeoutMs > 0) { "connectTimeoutMs must be positive" }
        require(readTimeoutMs > 0) { "readTimeoutMs must be positive" }
    }

    /**
     * Sends an OpenAI-compatible JSON request and returns the complete JSON response.
     * The configured model is injected when the request omits it.
     */
    @Throws(ModelGatewayException::class)
    fun chatCompletions(requestJson: String): String {
        val prepared = prepareRequest(requestJson, streaming = false)
        return executeWithRetry(prepared.config, prepared.body, JSON_MEDIA_TYPE) { connection, _ ->
            val status = connection.responseCode
            val body = readResponseBody(connection, status)
            if (status !in 200..299) throw mapHttpError(status, body)
            if (body.isBlank()) {
                throw ModelGatewayException.InvalidResponse("Model endpoint returned an empty response")
            }
            try {
                JSONObject(body)
            } catch (error: JSONException) {
                throw ModelGatewayException.InvalidResponse(
                    "Model endpoint returned non-JSON content",
                    error,
                )
            }
            body
        }
    }

    /**
     * Streams raw OpenAI-compatible SSE events. Each `data:` payload is delivered immediately;
     * callers can inspect [SseEvent.isDone] for the terminal `[DONE]` marker. The request body is
     * copied and `stream=true` is injected without changing the caller's JSON.
     */
    @Throws(ModelGatewayException::class)
    fun chatCompletionsStream(requestJson: String, onEvent: (SseEvent) -> Unit) {
        val prepared = prepareRequest(requestJson, streaming = true)
        executeWithRetry(prepared.config, prepared.body, SSE_MEDIA_TYPE) { connection, active ->
            val status = connection.responseCode
            if (status !in 200..299) {
                throw mapHttpError(status, readResponseBody(connection, status))
            }
            val contentType = connection.contentType.orEmpty()
            if (!contentType.substringBefore(';').trim().equals("text/event-stream", ignoreCase = true)) {
                throw ModelGatewayException.InvalidResponse(
                    "Streaming endpoint returned an unexpected content type: ${contentType.ifBlank { "unknown" }}",
                )
            }
            val parser = SseEventParser { event ->
                active.responseStarted = true
                onEvent(event)
            }
            connection.inputStream.bufferedReader(Charsets.UTF_8).useLines { lines ->
                lines.forEach { line ->
                    ensureNotCancelled(active)
                    parser.acceptLine(line.removeSuffix("\r"))
                }
            }
            parser.finish()
            Unit
        }
    }

    /** Disconnects the active buffered or streaming request. Safe to call when idle. */
    fun cancelCurrentRequest() {
        activeRequest.get()?.cancel()
    }

    private fun prepareRequest(requestJson: String, streaming: Boolean): PreparedRequest {
        val config = configStore.load()
            ?: throw ModelGatewayException.Configuration("Model configuration is missing")
        validateConfig(config)

        val request = try {
            JSONObject(requestJson)
        } catch (error: JSONException) {
            throw ModelGatewayException.InvalidRequest("Request must be a JSON object", error)
        }
        if (!request.has("model") || request.optString("model").isBlank()) {
            request.put("model", config.model)
        }
        if (streaming) {
            request.put("stream", true)
        }
        return PreparedRequest(config, request.toString())
    }

    private fun <T> executeWithRetry(
        config: ModelConfig,
        body: String,
        accept: String,
        consume: (HttpURLConnection, ActiveRequest) -> T,
    ): T {
        val request = ActiveRequest()
        activeRequest.getAndSet(request)?.cancel()
        var retryIndex = 0
        try {
            while (true) {
                ensureNotCancelled(request)
                val connection = try {
                    openConnection(resolveChatCompletionsUrl(config.endpoint))
                } catch (error: ModelGatewayException) {
                    throw error
                } catch (error: Exception) {
                    throw ModelGatewayException.Configuration("Invalid model endpoint", error)
                }
                request.connection.set(connection)
                request.responseStarted = false
                try {
                    ensureNotCancelled(request)
                    configureConnection(connection, config, accept)
                    connection.outputStream.bufferedWriter(Charsets.UTF_8).use { it.write(body) }
                    return consume(connection, request)
                } catch (error: Throwable) {
                    val mapped = mapTransportError(error, request)
                    if (
                        request.responseStarted ||
                        retryIndex >= retryPolicy.maxRetries ||
                        !retryPolicy.isRetryableFailure(mapped)
                    ) {
                        throw mapped
                    }
                    waitBeforeRetry(request, retryPolicy.delayBeforeRetry(retryIndex))
                    retryIndex += 1
                } finally {
                    request.connection.compareAndSet(connection, null)
                    connection.disconnect()
                }
            }
        } finally {
            activeRequest.compareAndSet(request, null)
        }
    }

    private fun configureConnection(connection: HttpURLConnection, config: ModelConfig, accept: String) {
        connection.requestMethod = "POST"
        connection.connectTimeout = connectTimeoutMs
        connection.readTimeout = readTimeoutMs
        connection.doOutput = true
        connection.useCaches = false
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept", accept)
        connection.setRequestProperty("Content-Type", JSON_MEDIA_TYPE)
        connection.setRequestProperty("Authorization", "Bearer ${config.apiKey}")
    }

    private fun readResponseBody(connection: HttpURLConnection, status: Int): String =
        (if (status in 200..299) connection.inputStream else connection.errorStream)
            ?.bufferedReader(Charsets.UTF_8)
            ?.use { it.readText() }
            .orEmpty()

    private fun mapTransportError(error: Throwable, request: ActiveRequest): ModelGatewayException {
        if (request.cancelled) return ModelGatewayException.Cancelled("Model request was cancelled")
        return when (error) {
            is ModelGatewayException -> error
            is SocketTimeoutException -> ModelGatewayException.Timeout("Model request timed out", error)
            is SSLException -> ModelGatewayException.Security("TLS validation failed", error)
            is SecurityException -> ModelGatewayException.Security(
                "Network request was blocked by Android security policy",
                error,
            )
            is NetworkOnMainThreadException -> ModelGatewayException.InvalidRequest(
                "Model requests must run off the main thread",
                error,
            )
            is IOException -> ModelGatewayException.Network("Model request failed", error)
            else -> throw error
        }
    }

    private fun waitBeforeRetry(request: ActiveRequest, delayMs: Long) {
        if (delayMs == 0L) return ensureNotCancelled(request)
        try {
            if (request.cancelledSignal.await(delayMs, TimeUnit.MILLISECONDS)) {
                throw ModelGatewayException.Cancelled("Model request was cancelled")
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            request.cancel()
            throw ModelGatewayException.Cancelled("Model request was cancelled", error)
        }
        ensureNotCancelled(request)
    }

    private fun ensureNotCancelled(request: ActiveRequest) {
        if (request.cancelled) throw ModelGatewayException.Cancelled("Model request was cancelled")
    }

    private fun openConnection(url: URL): HttpURLConnection {
        val connection = url.openConnection()
        if (connection !is HttpURLConnection) {
            throw ModelGatewayException.Security("Only HTTP(S) endpoints are supported")
        }
        if (url.protocol.equals("https", ignoreCase = true) && connection !is HttpsURLConnection) {
            connection.disconnect()
            throw ModelGatewayException.Security("Unable to create a secure HTTPS connection")
        }
        return connection
    }

    private fun resolveChatCompletionsUrl(endpoint: String): URL {
        val trimmed = endpoint.trim().trimEnd('/')
        val uri = try {
            URI(trimmed)
        } catch (error: Exception) {
            throw ModelGatewayException.Configuration("Endpoint is not a valid URI", error)
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && !(scheme == "http" && isLoopback(uri.host))) {
            throw ModelGatewayException.Security(
                "Endpoint must use HTTPS; HTTP is permitted only for loopback development endpoints",
            )
        }
        if (uri.host.isNullOrBlank() || uri.userInfo != null) {
            throw ModelGatewayException.Configuration("Endpoint must contain a valid host and no embedded credentials")
        }
        val finalUrl = if (trimmed.endsWith("/chat/completions")) {
            trimmed
        } else {
            "$trimmed/chat/completions"
        }
        return try {
            URL(finalUrl)
        } catch (error: Exception) {
            throw ModelGatewayException.Configuration("Endpoint cannot be converted to a URL", error)
        }
    }

    private fun validateConfig(config: ModelConfig) {
        if (config.endpoint.isBlank()) {
            throw ModelGatewayException.Configuration("Model endpoint is missing")
        }
        if (config.model.isBlank()) {
            throw ModelGatewayException.Configuration("Model name is missing")
        }
        if (config.apiKey.isBlank()) {
            throw ModelGatewayException.Configuration("API key is missing")
        }
        if (config.apiKey.contains('\n') || config.apiKey.contains('\r')) {
            throw ModelGatewayException.Security("API key contains invalid header characters")
        }
    }

    private fun mapHttpError(status: Int, body: String): ModelGatewayException {
        val serverMessage = extractErrorMessage(body)
        val message = if (serverMessage.isNullOrBlank()) {
            "Model endpoint returned HTTP $status"
        } else {
            "Model endpoint returned HTTP $status: $serverMessage"
        }
        return when (status) {
            401, 403 -> ModelGatewayException.Authentication(message, status)
            408, 504 -> ModelGatewayException.Timeout(message, httpStatus = status)
            429 -> ModelGatewayException.RateLimited(message, status)
            in 400..499 -> ModelGatewayException.InvalidRequest(message, httpStatus = status)
            else -> ModelGatewayException.Upstream(message, status)
        }
    }

    private fun extractErrorMessage(body: String): String? {
        if (body.isBlank()) return null
        return try {
            val root = JSONObject(body)
            val error = root.optJSONObject("error")
            (error?.optString("message") ?: root.optString("message"))
                .takeIf { it.isNotBlank() }
                ?.take(MAX_ERROR_MESSAGE_LENGTH)
        } catch (_: JSONException) {
            null
        }
    }

    private fun isLoopback(host: String?): Boolean = when (host?.lowercase()) {
        "localhost", "127.0.0.1", "::1", "[::1]" -> true
        else -> false
    }

    companion object {
        const val DEFAULT_CONNECT_TIMEOUT_MS = 15_000
        const val DEFAULT_READ_TIMEOUT_MS = 60_000
        private const val JSON_MEDIA_TYPE = "application/json; charset=utf-8"
        private const val SSE_MEDIA_TYPE = "text/event-stream"
        private const val MAX_ERROR_MESSAGE_LENGTH = 512
    }

    private data class PreparedRequest(val config: ModelConfig, val body: String)

    private class ActiveRequest {
        val connection = AtomicReference<HttpURLConnection?>()
        val cancelledSignal = CountDownLatch(1)
        @Volatile var cancelled: Boolean = false
        @Volatile var responseStarted: Boolean = false

        fun cancel() {
            cancelled = true
            cancelledSignal.countDown()
            connection.getAndSet(null)?.disconnect()
        }
    }
}

sealed class ModelGatewayException(
    message: String,
    cause: Throwable? = null,
    open val httpStatus: Int? = null,
) : Exception(message, cause) {
    class Configuration(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class InvalidRequest(
        message: String,
        cause: Throwable? = null,
        override val httpStatus: Int? = null,
    ) : ModelGatewayException(message, cause, httpStatus)

    class Authentication(message: String, override val httpStatus: Int?) :
        ModelGatewayException(message, httpStatus = httpStatus)

    class RateLimited(message: String, override val httpStatus: Int?) :
        ModelGatewayException(message, httpStatus = httpStatus)

    class Timeout(
        message: String,
        cause: Throwable? = null,
        override val httpStatus: Int? = null,
    ) : ModelGatewayException(message, cause, httpStatus)

    class Security(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Network(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class InvalidResponse(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Cancelled(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Upstream(message: String, override val httpStatus: Int?) :
        ModelGatewayException(message, httpStatus = httpStatus)
}
