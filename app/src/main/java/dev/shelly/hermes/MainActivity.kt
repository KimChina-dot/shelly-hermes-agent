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
        findViewById<Button>(R.id.pickDirectory).setOnClickListener { picker.launch(null) }
        findViewById<Button>(R.id.saveModel).setOnClickListener {
            val endpoint = findViewById<EditText>(R.id.endpoint).text.toString()
            val model = findViewById<EditText>(R.id.model).text.toString()
            val key = findViewById<EditText>(R.id.apiKey).text.toString()
            if (!endpoint.startsWith("https://") || key.isBlank()) Toast.makeText(this, "请输入 HTTPS 端点和密钥", Toast.LENGTH_SHORT).show()
            else { AndroidKeyStoreModelConfig(this).save(ModelConfig(endpoint, model, key)); findViewById<EditText>(R.id.apiKey).text.clear(); Toast.makeText(this, "已加密保存", Toast.LENGTH_SHORT).show() }
        }
        findViewById<Button>(R.id.startTask).setOnClickListener { ContextCompat.startForegroundService(this, Intent(this, TaskForegroundService::class.java)) }
        findViewById<Button>(R.id.approval).setOnClickListener { startActivity(Intent(this, ApprovalActivity::class.java)) }
    }
}
