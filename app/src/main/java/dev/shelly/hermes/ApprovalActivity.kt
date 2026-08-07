package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.widget.Button

class ApprovalActivity : Activity() {
    override fun onCreate(state: Bundle?) { super.onCreate(state); setContentView(R.layout.activity_approval); findViewById<Button>(R.id.approve).setOnClickListener { setResult(RESULT_OK); finish() }; findViewById<Button>(R.id.reject).setOnClickListener { setResult(RESULT_CANCELED); finish() } }
}
