package dev.shelly.hermes

import dev.shelly.hermes.core.ToolApprovalPolicy
import dev.shelly.hermes.core.ToolCall
import dev.shelly.hermes.core.ToolCapabilityAuthorizer
import dev.shelly.hermes.core.ToolExecutor
import dev.shelly.hermes.core.ToolPluginManifest
import dev.shelly.hermes.core.ToolPluginRuntime
import kotlinx.coroutines.sync.Mutex

/** ToolExecutor compatibility adapter backed by the Android workspace plugin registry. */
class SafWorkspaceToolExecutor(
    files: SafWorkspaceFileExecutor,
) : ToolExecutor {
    private val catalog = AndroidWorkspaceToolPlugins.manifests
    private val runtime = ToolPluginRuntime(
        ToolCapabilityAuthorizer.granted(catalog.mapTo(linkedSetOf<String>()) { it.capability }),
    ).also {
        AndroidWorkspaceToolPlugins.registerAll(it, files)
    }
    private val lifecycleLock = Mutex()

    override suspend fun execute(call: ToolCall): String {
        // Serialize one-time lifecycle transitions without blocking an Android worker thread.
        lifecycleLock.lock()
        try {
            runtime.start(call.name)
        } finally {
            lifecycleLock.unlock()
        }
        return runtime.execute(call)
    }

    fun manifests(): List<ToolPluginManifest> = runtime.manifests()

    fun approvalPolicy(): ToolApprovalPolicy = runtime.approvalPolicy()
}
