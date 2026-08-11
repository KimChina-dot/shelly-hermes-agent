package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import dev.shelly.hermes.core.ApprovalDecision

/**
 * Human approval screen for a single pending tool call.
 *
 * Reads the currently pending request from [ApprovalBridge.gateway] and lets the user approve
 * or reject the tool call. The decision is pushed back into the gateway, resuming the suspended
 * agent coroutine that is waiting for approval.
 */
class ApprovalActivity : Activity() {

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        setContentView(R.layout.activity_approval)

        val pending = ApprovalBridge.gateway.active
        val name = findViewById<TextView>(R.id.tool_name)
        val args = findViewById<TextView>(R.id.tool_args)
        val empty = findViewById<TextView>(R.id.empty)

        if (pending == null) {
            name.visibility = android.view.View.GONE
            args.visibility = android.view.View.GONE
            empty.visibility = android.view.View.VISIBLE
            findViewById<Button>(R.id.approve).isEnabled = false
            findViewById<Button>(R.id.reject).isEnabled = false
        } else {
            name.text = "工具调用：${pending.call.name}"
            args.text = pending.call.argumentsJson.takeIf { it.isNotBlank() } ?: "（无参数）"
        }

        findViewById<Button>(R.id.approve).setOnClickListener {
            ApprovalBridge.gateway.resolve(ApprovalDecision.APPROVE)
            setResult(RESULT_OK)
            finish()
        }
        findViewById<Button>(R.id.reject).setOnClickListener {
            ApprovalBridge.gateway.resolve(ApprovalDecision.REJECT)
            setResult(RESULT_CANCELED)
            finish()
        }
    }
}

/** Application-wide bridge so the approval screen and the gateway share one instance. */
object ApprovalBridge {
    val gateway = AndroidApprovalGateway()
}