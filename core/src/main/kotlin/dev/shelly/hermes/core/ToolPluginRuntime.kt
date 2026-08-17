package dev.shelly.hermes.core

import kotlinx.coroutines.withTimeout

enum class ToolRisk { LOW, MEDIUM, HIGH }

enum class CheckpointRequirement { NONE, BEST_EFFORT, REQUIRED }

data class ToolPluginManifest(
    val name: String,
    val capability: String,
    val risk: ToolRisk,
    val requiresApproval: Boolean,
    val timeoutMillis: Long,
    val maxOutputChars: Int,
    val checkpointRequirement: CheckpointRequirement,
    val failureThreshold: Int,
    val circuitResetMillis: Long,
) {
    init {
        require(name.isNotBlank() && name == name.trim()) { "Tool plugin name must be non-blank and trimmed" }
        require(capability.isNotBlank() && capability == capability.trim()) {
            "Tool plugin capability must be non-blank and trimmed"
        }
        require(timeoutMillis > 0) { "timeoutMillis must be positive" }
        require(maxOutputChars > 0) { "maxOutputChars must be positive" }
        require(failureThreshold > 0) { "failureThreshold must be positive" }
        require(circuitResetMillis >= 0) { "circuitResetMillis must be non-negative" }
    }
}

interface ToolPlugin {
    val manifest: ToolPluginManifest

    suspend fun start() = Unit

    suspend fun stop() = Unit

    suspend fun execute(call: ToolCall): String
}

enum class ToolPluginLifecycle { STOPPED, STARTING, RUNNING, STOPPING }

enum class ToolCircuitState { CLOSED, OPEN, HALF_OPEN }

data class ToolPluginStatus(
    val name: String,
    val lifecycle: ToolPluginLifecycle,
    val circuit: ToolCircuitState,
    val consecutiveFailures: Int,
)

fun interface ToolCapabilityAuthorizer {
    fun isAllowed(capability: String): Boolean

    companion object {
        val ALLOW_ALL = ToolCapabilityAuthorizer { true }

        fun granted(capabilities: Set<String>) = ToolCapabilityAuthorizer(capabilities::contains)
    }
}

enum class ToolPluginErrorCode {
    ALREADY_REGISTERED,
    NOT_REGISTERED,
    NOT_RUNNING,
    CAPABILITY_DENIED,
    CIRCUIT_OPEN,
}

class ToolPluginException(
    message: String,
    val code: ToolPluginErrorCode,
    val pluginName: String,
) : IllegalStateException(message)

/** Android/JVM reliability and policy boundary for model-visible tools. */
class ToolPluginRuntime(
    private val capabilityAuthorizer: ToolCapabilityAuthorizer = ToolCapabilityAuthorizer.ALLOW_ALL,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private class Entry(val plugin: ToolPlugin) {
        var lifecycle = ToolPluginLifecycle.STOPPED
        var failures = 0
        var openedAt: Long? = null
        var probeInFlight = false
    }

    private val entries = linkedMapOf<String, Entry>()

    fun register(plugin: ToolPlugin) {
        val name = plugin.manifest.name
        synchronized(entries) {
            if (entries.containsKey(name)) {
                throw ToolPluginException(
                    "Tool plugin '$name' is already registered",
                    ToolPluginErrorCode.ALREADY_REGISTERED,
                    name,
                )
            }
            entries[name] = Entry(plugin)
        }
    }

    fun manifests(): List<ToolPluginManifest> = synchronized(entries) {
        entries.values.map { it.plugin.manifest }
    }

    fun listManifests(): List<ToolPluginManifest> = manifests()

    fun status(name: String): ToolPluginStatus = synchronized(entries) {
        val entry = requireEntryLocked(name)
        ToolPluginStatus(name, entry.lifecycle, circuitState(entry), entry.failures)
    }

    suspend fun start(name: String) {
        val entry = synchronized(entries) {
            requireEntryLocked(name).also {
                if (it.lifecycle == ToolPluginLifecycle.RUNNING) return
                check(it.lifecycle == ToolPluginLifecycle.STOPPED) { "Tool plugin '$name' is changing lifecycle" }
                it.lifecycle = ToolPluginLifecycle.STARTING
            }
        }
        try {
            entry.plugin.start()
            synchronized(entries) { entry.lifecycle = ToolPluginLifecycle.RUNNING }
        } catch (error: Throwable) {
            synchronized(entries) { entry.lifecycle = ToolPluginLifecycle.STOPPED }
            throw error
        }
    }

    suspend fun stop(name: String) {
        val entry = synchronized(entries) {
            requireEntryLocked(name).also {
                if (it.lifecycle == ToolPluginLifecycle.STOPPED) return
                check(it.lifecycle == ToolPluginLifecycle.RUNNING) { "Tool plugin '$name' is changing lifecycle" }
                it.lifecycle = ToolPluginLifecycle.STOPPING
            }
        }
        try {
            entry.plugin.stop()
        } finally {
            synchronized(entries) {
                entry.lifecycle = ToolPluginLifecycle.STOPPED
                entry.failures = 0
                entry.openedAt = null
                entry.probeInFlight = false
            }
        }
    }

    suspend fun startAll() {
        manifests().forEach { start(it.name) }
    }

    suspend fun stopAll() {
        manifests().asReversed().forEach { stop(it.name) }
    }

    suspend fun execute(call: ToolCall): String = executeDeclared(call, null)

    suspend fun execute(call: ToolCall, requiredCapability: String): String =
        executeDeclared(call, requiredCapability)

    private suspend fun executeDeclared(call: ToolCall, requiredCapability: String?): String {
        val entry = synchronized(entries) {
            val candidate = requireEntryLocked(call.name)
            if (candidate.lifecycle != ToolPluginLifecycle.RUNNING) {
                throw ToolPluginException(
                    "Tool plugin '${call.name}' is not running",
                    ToolPluginErrorCode.NOT_RUNNING,
                    call.name,
                )
            }
            if (requiredCapability != null && requiredCapability != candidate.plugin.manifest.capability) {
                throw ToolPluginException(
                    "Tool plugin '${call.name}' does not declare capability '$requiredCapability'",
                    ToolPluginErrorCode.CAPABILITY_DENIED,
                    call.name,
                )
            }
            if (!capabilityAuthorizer.isAllowed(candidate.plugin.manifest.capability)) {
                throw ToolPluginException(
                    "Capability '${candidate.plugin.manifest.capability}' is not granted to '${call.name}'",
                    ToolPluginErrorCode.CAPABILITY_DENIED,
                    call.name,
                )
            }
            acquireCircuitLocked(candidate)
            candidate
        }

        try {
            val output = withTimeout(entry.plugin.manifest.timeoutMillis) { entry.plugin.execute(call) }
            synchronized(entries) {
                entry.failures = 0
                entry.openedAt = null
            }
            return truncate(output, entry.plugin.manifest.maxOutputChars)
        } catch (error: Throwable) {
            synchronized(entries) {
                entry.failures += 1
                if (entry.failures >= entry.plugin.manifest.failureThreshold) {
                    entry.openedAt = nowMillis()
                }
            }
            throw error
        } finally {
            synchronized(entries) { entry.probeInFlight = false }
        }
    }

    fun asToolExecutor() = ToolExecutor { execute(it) }

    /** Unknown tools remain approval-gated so registry mistakes cannot bypass user review. */
    fun approvalPolicy() = ToolApprovalPolicy { call ->
        synchronized(entries) { entries[call.name]?.plugin?.manifest?.requiresApproval ?: true }
    }

    fun toApprovalPolicy(): ToolApprovalPolicy = approvalPolicy()

    private fun requireEntryLocked(name: String): Entry = entries[name] ?: throw ToolPluginException(
        "Tool plugin '$name' is not registered",
        ToolPluginErrorCode.NOT_REGISTERED,
        name,
    )

    private fun circuitState(entry: Entry): ToolCircuitState {
        val openedAt = entry.openedAt ?: return ToolCircuitState.CLOSED
        return if (nowMillis() - openedAt >= entry.plugin.manifest.circuitResetMillis) {
            ToolCircuitState.HALF_OPEN
        } else {
            ToolCircuitState.OPEN
        }
    }

    private fun acquireCircuitLocked(entry: Entry) {
        val state = circuitState(entry)
        if (state == ToolCircuitState.OPEN || state == ToolCircuitState.HALF_OPEN && entry.probeInFlight) {
            val name = entry.plugin.manifest.name
            throw ToolPluginException(
                "Circuit for tool plugin '$name' is open",
                ToolPluginErrorCode.CIRCUIT_OPEN,
                name,
            )
        }
        if (state == ToolCircuitState.HALF_OPEN) entry.probeInFlight = true
    }

    private fun truncate(output: String, maxChars: Int): String {
        if (output.length <= maxChars) return output
        val marker = "\n...[truncated]"
        if (maxChars <= marker.length) return output.take(maxChars)
        return output.take(maxChars - marker.length) + marker
    }
}
