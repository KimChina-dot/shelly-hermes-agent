package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.TextView
import dev.shelly.hermes.core.ApprovalDecision
import dev.shelly.hermes.core.ToolRisk
import org.json.JSONObject

/** Human approval screen for the currently pending tool call. */
class ApprovalActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_approval)

        val pending = ApprovalBridge.gateway.active
        val name = findViewById<TextView>(R.id.tool_name)
        val args = findViewById<TextView>(R.id.tool_args)
        val empty = findViewById<View>(R.id.empty)
        val riskTitle = findViewById<TextView>(R.id.risk_title)
        val risk = findViewById<TextView>(R.id.risk)
        val targetTitle = findViewById<TextView>(R.id.affected_title)
        val target = findViewById<TextView>(R.id.affected_target)
        val toolTitle = findViewById<TextView>(R.id.tool_section_title)
        val argsTitle = findViewById<TextView>(R.id.args_section_title)
        val summaryTitle = findViewById<TextView>(R.id.summary_title)
        val summary = findViewById<TextView>(R.id.approval_summary)
        val expandArgs = findViewById<TextView>(R.id.expand_args)
        val approve = findViewById<Button>(R.id.approve)
        val reject = findViewById<Button>(R.id.reject)
        val always = findViewById<Button>(R.id.always)
        val actionRow = findViewById<View>(R.id.actionRow)
        val emptyAction = findViewById<Button>(R.id.emptyAction)
        emptyAction.setOnClickListener { finish() }
        var argsExpanded = false
        expandArgs.setOnClickListener {
            argsExpanded = !argsExpanded
            args.visibility = if (argsExpanded) View.VISIBLE else View.GONE
            expandArgs.text = getString(
                if (argsExpanded) R.string.collapse_args else R.string.expand_args,
            )
            expandArgs.contentDescription =
                "${if (argsExpanded) "收起" else "查看"} ${pending?.call.name.orEmpty()} 技术参数"
        }

        if (pending == null) {
            name.visibility = View.GONE
            args.visibility = View.GONE
            empty.visibility = View.VISIBLE
            riskTitle.visibility = View.GONE
            risk.visibility = View.GONE
            targetTitle.visibility = View.GONE
            target.visibility = View.GONE
            toolTitle.visibility = View.GONE
            argsTitle.visibility = View.GONE
            summaryTitle.visibility = View.GONE
            summary.visibility = View.GONE
            expandArgs.visibility = View.GONE
            empty.contentDescription = "当前没有待审批的工具调用，可以返回工作台发起新任务"
            emptyAction.contentDescription = "返回工作台"
            actionRow.visibility = View.GONE
            always.visibility = View.GONE
            approve.isEnabled = false
            reject.isEnabled = false
            always.isEnabled = false
        } else {
            name.text = "工具调用：${pending.call.name}"
            toolTitle.visibility = View.VISIBLE
            argsTitle.visibility = View.VISIBLE
            summaryTitle.visibility = View.VISIBLE
            args.text = pending.call.argumentsJson.takeIf { it.isNotBlank() } ?: "（无参数）"
            summary.text = ToolSummaries.parameterSummary(
                pending.call.name,
                pending.call.argumentsJson,
            )
            name.contentDescription = "待审批工具 ${pending.call.name}"
            args.contentDescription = "待审批参数与变更内容"
            summary.contentDescription = "参数摘要 ${summary.text}"
            val riskLevel = approvalRisk(pending.call.name)
            riskTitle.visibility = View.VISIBLE
            risk.visibility = View.VISIBLE
            empty.visibility = View.GONE
            actionRow.visibility = View.VISIBLE
            always.visibility = View.VISIBLE
            risk.text = riskLabel(riskLevel)
            risk.setBackgroundResource(riskBackground(riskLevel))
            risk.setTextColor(getColor(riskTextColor(riskLevel)))
            risk.contentDescription = riskLabel(riskLevel)
            targetTitle.visibility = View.VISIBLE
            target.visibility = View.VISIBLE
            target.text = approvalTarget(pending.call.argumentsJson)
            target.contentDescription = "影响对象 ${target.text}"
            summary.visibility = View.VISIBLE
            args.visibility = View.GONE
            expandArgs.visibility = View.VISIBLE
            expandArgs.text = getString(R.string.expand_args)
            expandArgs.contentDescription = "查看 ${pending.call.name} 技术参数"
            approve.contentDescription = "允许一次执行 ${pending.call.name}"
            reject.contentDescription = "拒绝执行 ${pending.call.name}"
            always.contentDescription = "本次任务始终允许 ${pending.call.name}"
        }

        approve.setOnClickListener {
            ApprovalBridge.gateway.resolve(ApprovalDecision.APPROVE)
            setResult(RESULT_OK)
            finish()
        }
        reject.setOnClickListener {
            ApprovalBridge.gateway.resolve(ApprovalDecision.REJECT)
            setResult(RESULT_CANCELED)
            finish()
        }
        always.setOnClickListener {
            pending?.let { ApprovalBridge.gateway.allowAlways(it.call.name) }
            setResult(RESULT_OK)
            finish()
        }
    }

    private fun approvalRisk(toolName: String): ToolRisk = when {
        toolName == "apply_patch_hunk" -> ToolRisk.MEDIUM
        else -> AndroidWorkspaceToolPlugins.manifests
            .firstOrNull { it.name == toolName }?.risk ?: ToolRisk.HIGH
    }

    private fun riskLabel(risk: ToolRisk): String = when (risk) {
        ToolRisk.LOW -> "风险等级：低，仍建议检查目标对象"
        ToolRisk.MEDIUM -> "风险等级：中，执行前需要人工确认"
        ToolRisk.HIGH -> "风险等级：高，请仔细确认影响对象"
    }

    private fun riskBackground(risk: ToolRisk): Int = when (risk) {
        ToolRisk.LOW -> R.drawable.bg_chip_success
        ToolRisk.MEDIUM -> R.drawable.bg_chip_warning
        ToolRisk.HIGH -> R.drawable.bg_chip_error
    }

    private fun riskTextColor(risk: ToolRisk): Int = when (risk) {
        ToolRisk.LOW -> R.color.status_success
        ToolRisk.MEDIUM -> R.color.status_warning
        ToolRisk.HIGH -> R.color.status_error
    }

    private fun approvalTarget(argumentsJson: String): String {
        val arguments = runCatching { JSONObject(argumentsJson.ifBlank { "{}"}) }.getOrNull()
        val path = arguments?.optString("path").orEmpty()
        if (path.isNotBlank()) {
            val hunkIndex = arguments?.optInt("hunk_index", 0) ?: 0
            val hunkCount = arguments?.optInt("hunk_count", 0) ?: 0
            return if (hunkIndex > 0 && hunkCount > 0) {
                "$path · 第 $hunkIndex/$hunkCount 段"
            } else {
                path
            }
        }
        val command = arguments?.optString("command").orEmpty()
        if (command.isNotBlank()) return command.take(240)
        val server = arguments?.optString("server").orEmpty()
        val tool = arguments?.optString("tool").orEmpty()
        if (server.isNotBlank() || tool.isNotBlank()) return "$server / $tool"
        return "当前工作区"
    }
}

/** Application-wide bridge shared by the service and approval screen. */
object ApprovalBridge {
    val gateway = AndroidApprovalGateway()
}
