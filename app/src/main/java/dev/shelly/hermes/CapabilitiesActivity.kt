package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import dev.shelly.hermes.core.ToolRisk
import dev.shelly.hermes.core.AgentProfileRegistry

/** Read-only view of the capabilities exposed to the current task. */
class CapabilitiesActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_capabilities)

        val model = AndroidKeyStoreModelConfig(this).load()
        val workspace = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.WORKSPACE_URI, null)

        findViewById<TextView>(R.id.modelCapability).text = if (model == null) {
            "模型\n未配置。返回工作台完成模型设置后，任务才能调用远程模型。"
        } else {
            "模型\n${model.model}\n${model.endpoint}"
        }
        findViewById<TextView>(R.id.workspaceCapability).text = if (workspace.isNullOrBlank()) {
            "工作区\n未授权 SAF 项目目录。"
        } else {
            "工作区\n已授权项目目录，仅允许访问目录内的相对路径。"
        }
        val allManifests = AndroidWorkspaceToolPlugins.manifests
        val profileId = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.AGENT_PROFILE_ID, "coding")
            .orEmpty()
        val profile = AgentProfileRegistry().findProfile(profileId)
        val manifests = allManifests.filter { profile == null || it.name in profile.toolNames }
        findViewById<TextView>(R.id.toolCapability).text = manifests.joinToString("\n\n") { manifest ->
            val risk = when (manifest.risk) {
                ToolRisk.LOW -> "低风险"
                ToolRisk.MEDIUM -> "中风险"
                ToolRisk.HIGH -> "高风险"
            }
            buildString {
                append(manifest.name)
                append("  ·  ")
                append(risk)
                append("\n")
                append(manifest.capability)
                append("  ·  超时 ")
                append(manifest.timeoutMillis / 1_000)
                append(" 秒  ·  ")
                append(if (manifest.requiresApproval) "需要审批" else "自动执行")
            }
        }
        val approvals = manifests.count { it.requiresApproval }
        findViewById<TextView>(R.id.securityCapability).text =
            "当前角色：${profile?.name ?: "Coding"}。已注册 ${manifests.size} 个工具插件，其中 $approvals 个写入工具强制审批。每个插件独立声明能力、风险、超时、输出上限、checkpoint 和熔断策略；工具不接受绝对路径、路径穿越或 shell 命令。"
    }
}
