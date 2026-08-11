package dev.shelly.hermes

import android.content.Intent
import android.os.Bundle
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity : androidx.activity.ComponentActivity() {
    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@registerForActivityResult
        contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        getSharedPreferences("public_config", MODE_PRIVATE).edit().putString("workspace_uri", uri.toString()).apply()
        findViewById<TextView>(R.id.workspace).text = "工作目录：$uri"
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state); setContentView(R.layout.activity_main)
        findViewById<Button>(R.id.chooseWorkspace).setOnClickListener { picker.launch(null) }
        findViewById<Button>(R.id.settings).setOnClickListener {
            Toast.makeText(this, "模型设置界面正在接入", Toast.LENGTH_SHORT).show()
        }
        findViewById<Button>(R.id.startTask).setOnClickListener { ContextCompat.startForegroundService(this, Intent(this, TaskForegroundService::class.java)) }
        findViewById<Button>(R.id.approval).setOnClickListener { startActivity(Intent(this, ApprovalActivity::class.java)) }
    }
}
