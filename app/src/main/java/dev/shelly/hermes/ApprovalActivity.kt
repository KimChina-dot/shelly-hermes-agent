package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.TextView
import dev.shelly.hermes.core.ApprovalDecision

/** Human approval screen for the currently pending tool call. */
class ApprovalActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_approval)

        val pending = ApprovalBridge.gateway.active
        val name = findViewById<TextView>(R.id.tool_name)
        val args = findViewById<TextView>(R.id.tool_args)
        val empty = findViewById<TextView>(R.id.empty)
        val approve = findViewById<Button>(R.id.approve)
        val reject = findViewById<Button>(R.id.reject)
        val always = findViewById<Button>(R.id.always)

        if (pending == null) {
            name.visibility = View.GONE
            args.visibility = View.GONE
            empty.visibility = View.VISIBLE
            approve.isEnabled = false
            reject.isEnabled = false
            always.isEnabled = false
        } else {
            name.text = "工具调用：${pending.call.name}"
            args.text = pending.call.argumentsJson.takeIf { it.isNotBlank() } ?: "（无参数）"
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
}

/** Application-wide bridge shared by the service and approval screen. */
object ApprovalBridge {
    val gateway = AndroidApprovalGateway()
}
