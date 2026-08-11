package dev.shelly.hermes

import android.os.NetworkOnMainThreadException
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
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
) {
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

        val connection = try {
            openConnection(resolveChatCompletionsUrl(config.endpoint))
        } catch (error: ModelGatewayException) {
            throw error
        } catch (error: Exception) {
            throw ModelGatewayException.Configuration("Invalid model endpoint", error)
        }

        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.doOutput = true
            connection.useCaches = false
            connection.setRequestProperty("Accept", JSON_MEDIA_TYPE)
            connection.setRequestProperty("Content-Type", JSON_MEDIA_TYPE)
            connection.setRequestProperty("Authorization", "Bearer ${config.apiKey}")

            connection.outputStream.bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(request.toString())
            }

            val status = connection.responseCode
            val body = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader(Charsets.UTF_8)
                ?.use { it.readText() }
                .orEmpty()

            if (status !in 200..299) {
                throw mapHttpError(status, body)
            }
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
            return body
        } catch (error: ModelGatewayException) {
            throw error
        } catch (error: SocketTimeoutException) {
            throw ModelGatewayException.Timeout("Model request timed out", error)
        } catch (error: SSLException) {
            throw ModelGatewayException.Security("TLS validation failed", error)
        } catch (error: SecurityException) {
            throw ModelGatewayException.Security("Network request was blocked by Android security policy", error)
        } catch (error: NetworkOnMainThreadException) {
            throw ModelGatewayException.InvalidRequest("Model requests must run off the main thread", error)
        } catch (error: IOException) {
            throw ModelGatewayException.Network("Model request failed", error)
        } finally {
            connection.disconnect()
        }
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
            408, 504 -> ModelGatewayException.Timeout(message)
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
        private const val MAX_ERROR_MESSAGE_LENGTH = 512
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

    class Timeout(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Security(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Network(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class InvalidResponse(message: String, cause: Throwable? = null) :
        ModelGatewayException(message, cause)

    class Upstream(message: String, override val httpStatus: Int?) :
        ModelGatewayException(message, httpStatus = httpStatus)
}
