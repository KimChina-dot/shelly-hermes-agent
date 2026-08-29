package dev.shelly.hermes

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import dev.shelly.hermes.core.ToolRisk
import dev.shelly.hermes.core.AgentProfileRegistry
import dev.shelly.hermes.core.ToolPluginManifest

/** Read-only view of the capabilities exposed to the current task. */
class CapabilitiesActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_capabilities)

        val model = AndroidKeyStoreModelConfig(this).load()
        val workspace = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.WORKSPACE_URI, null)
        val modelStatus = findViewById<TextView>(R.id.modelCapabilityStatus)
        val modelBody = findViewById<TextView>(R.id.modelCapabilityBody)
        val workspaceStatus = findViewById<TextView>(R.id.workspaceCapabilityStatus)
        val workspaceBody = findViewById<TextView>(R.id.workspaceCapabilityBody)
        val toolList = findViewById<LinearLayout>(R.id.toolCapabilityList)
        val toolEmpty = findViewById<TextView>(R.id.toolCapabilityEmpty)
        val toolSummary = findViewById<TextView>(R.id.toolCapabilitySummary)

        modelStatus.text = if (model == null) "未配置" else "已配置"
        modelStatus.setBackgroundResource(if (model == null) R.drawable.bg_chip_warning else R.drawable.bg_chip_success)
        modelStatus.setTextColor(
            getColor(if (model == null) R.color.status_warning else R.color.status_success),
        )
        modelStatus.contentDescription = "模型状态 ${modelStatus.text}"
        modelBody.text = if (model == null) {
            "返回工作台完成模型设置后，任务才能调用远程模型。"
        } else {
            "${model.model}\n${model.endpoint}"
        }
        modelBody.contentDescription = modelBody.text

        workspaceStatus.text = if (workspace.isNullOrBlank()) "未授权" else "已授权"
        workspaceStatus.setBackgroundResource(
            if (workspace.isNullOrBlank()) R.drawable.bg_chip_warning else R.drawable.bg_chip_success,
        )
        workspaceStatus.setTextColor(
            getColor(if (workspace.isNullOrBlank()) R.color.status_warning else R.color.status_success),
        )
        workspaceStatus.contentDescription = "工作区状态 ${workspaceStatus.text}"
        workspaceBody.text = if (workspace.isNullOrBlank()) {
            "尚未授权 SAF 项目目录。"
        } else {
            "已授权项目目录，仅允许访问目录内的相对路径。"
        }
        workspaceBody.contentDescription = workspaceBody.text

        val allManifests = AndroidWorkspaceToolPlugins.manifests
        val profileId = getSharedPreferences(MainActivity.PUBLIC_CONFIG, MODE_PRIVATE)
            .getString(MainActivity.AGENT_PROFILE_ID, "coding")
            .orEmpty()
        val profile = AgentProfileRegistry().findProfile(profileId)
        val manifests = allManifests.filter { profile == null || it.name in profile.toolNames }
        toolList.removeAllViews()
        toolEmpty.visibility = if (manifests.isEmpty()) View.VISIBLE else View.GONE
        val approvals = manifests.count { it.requiresApproval }
        val profileName = profile?.name ?: if (profileId == MainActivity.TEAM_PROFILE_ID) {
            "Standard Team"
        } else {
            "Coding"
        }
        toolSummary.text = "$profileName · ${manifests.size} 个工具 · $approvals 个需审批"
        toolSummary.contentDescription = toolSummary.text
        manifests.forEach { manifest ->
            toolList.addView(toolCard(manifest))
        }

        findViewById<TextView>(R.id.securityCapability).text =
            "每个插件独立声明能力、风险、超时、输出上限、checkpoint 和熔断策略；工具不接受绝对路径、路径穿越或 shell 命令。"
        findViewById<TextView>(R.id.securityCapability).contentDescription =
            findViewById<TextView>(R.id.securityCapability).text
    }

    private fun toolCard(manifest: ToolPluginManifest): LinearLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ContextCompat.getDrawable(context, R.drawable.bg_surface_card)
            setPadding(dp(14), dp(14), dp(14), dp(14))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(10) }
            contentDescription = "工具 ${manifest.name}，${riskLabel(manifest.risk)}，${
                if (manifest.requiresApproval) "需要审批" else "自动执行"
            }"
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(TextView(this).apply {
            text = manifest.name
            setTextAppearance(R.style.TextAppearance_Luma_SectionTitle)
            layoutParams = LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f,
            )
        })
        header.addView(statusChip(riskLabel(manifest.risk), riskBackground(manifest.risk), riskColor(manifest.risk)))
        card.addView(header)

        card.addView(TextView(this).apply {
            text = manifest.capability
            textSize = 13f
            setTextColor(getColor(R.color.text_secondary))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8) }
        })
        card.addView(TextView(this).apply {
            text = buildString {
                append("超时 ${manifest.timeoutMillis / 1_000} 秒 · ")
                append(if (manifest.requiresApproval) "需要审批" else "自动执行")
            }
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(getColor(R.color.text_tertiary))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(6) }
        })
        return card
    }

    private fun statusChip(label: String, background: Int, textColor: Int): TextView {
        return TextView(this).apply {
            text = label
            textSize = 12f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(getColor(textColor))
            background = ContextCompat.getDrawable(context, background)
            setPadding(dp(8), dp(2), dp(8), dp(2))
            contentDescription = "状态 $label"
        }
    }

    private fun riskLabel(risk: ToolRisk): String = when (risk) {
        ToolRisk.LOW -> "低风险"
        ToolRisk.MEDIUM -> "中风险"
        ToolRisk.HIGH -> "高风险"
    }

    private fun riskBackground(risk: ToolRisk): Int = when (risk) {
        ToolRisk.LOW -> R.drawable.bg_chip_success
        ToolRisk.MEDIUM -> R.drawable.bg_chip_warning
        ToolRisk.HIGH -> R.drawable.bg_chip_error
    }

    private fun riskColor(risk: ToolRisk): Int = when (risk) {
        ToolRisk.LOW -> R.color.status_success
        ToolRisk.MEDIUM -> R.color.status_warning
        ToolRisk.HIGH -> R.color.status_error
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
