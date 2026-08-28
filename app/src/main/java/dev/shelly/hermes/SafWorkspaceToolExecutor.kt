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
    shell: ShellToolExecutor? = null,
    backups: WorkspaceBackupStore? = null,
    shellSessions: ShellSessionManager? = null,
    mcp: McpToolBridge? = null,
    allowedCapabilities: Set<String> = AndroidWorkspaceToolPlugins.manifests.mapTo(linkedSetOf<String>()) { it.capability },
    private val allowedToolNames: Set<String> = AndroidWorkspaceToolPlugins.manifests.mapTo(linkedSetOf<String>()) { it.name },
) : ToolExecutor {
    private val catalog = AndroidWorkspaceToolPlugins.manifests
    private val runtime = ToolPluginRuntime(
        ToolCapabilityAuthorizer.granted(allowedCapabilities),
    ).also {
        AndroidWorkspaceToolPlugins.registerAll(it, files, shell, backups, shellSessions, mcp)
    }
    private val lifecycleLock = Mutex()

    override suspend fun execute(call: ToolCall): String {
        require(call.name in allowedToolNames) { "Tool '${call.name}' is not enabled for this agent profile" }
        // Serialize one-time lifecycle transitions without blocking an Android worker thread.
        lifecycleLock.lock()
        try {
            runtime.start(call.name)
        } finally {
            lifecycleLock.unlock()
        }
        return runtime.execute(call)
    }

    fun manifests(): List<ToolPluginManifest> = runtime.manifests().filter { it.name in allowedToolNames }

    fun approvalPolicy(): ToolApprovalPolicy = runtime.approvalPolicy()
}
