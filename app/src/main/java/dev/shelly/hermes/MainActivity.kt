package dev.shelly.hermes

import android.content.Intent
import android.os.Bundle
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity : androidx.activity.ComponentActivity() {
    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@registerForActivityResult
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (error: SecurityException) {
            Toast.makeText(this, "无法持久化目录权限，请重新选择目录", Toast.LENGTH_LONG).show()
            return@registerForActivityResult
        }
        getSharedPreferences("public_config", MODE_PRIVATE).edit().putString("workspace_uri", uri.toString()).apply()
        findViewById<TextView>(R.id.workspace).text = "工作目录：$uri"
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state); setContentView(R.layout.activity_main)
        findViewById<Button>(R.id.chooseWorkspace).setOnClickListener { picker.launch(null) }
        findViewById<Button>(R.id.settings).setOnClickListener {
            showModelSettingsDialog()
        }
        findViewById<Button>(R.id.startTask).setOnClickListener { ContextCompat.startForegroundService(this, Intent(this, TaskForegroundService::class.java)) }
        findViewById<Button>(R.id.approval).setOnClickListener { startActivity(Intent(this, ApprovalActivity::class.java)) }
    }
    private fun showModelSettingsDialog() {
        val store = AndroidKeyStoreModelConfig(this)
        val current = store.load()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (20 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding / 2, padding, 0)
        }
        val endpoint = EditText(this).apply {
            hint = "API 地址，例如 https://api.example.com/v1"
            setText(current?.endpoint.orEmpty())
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
        }
        val model = EditText(this).apply {
            hint = "模型名称"
            setText(current?.model.orEmpty())
        }
        val apiKey = EditText(this).apply {
            hint = if (current?.apiKey.isNullOrBlank()) "API Key" else "API Key（留空则保留现有密钥）"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        container.addView(endpoint)
        container.addView(model)
        container.addView(apiKey)
        val dialog = androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("模型设置")
            .setView(container)
            .setNegativeButton("取消", null)
            .setPositiveButton("保存", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(androidx.appcompat.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val endpointValue = endpoint.text.toString().trim().trimEnd('/')
                val modelValue = model.text.toString().trim()
                val keyValue = apiKey.text.toString().trim().ifBlank { current?.apiKey.orEmpty() }
                if (!endpointValue.startsWith("https://") && !endpointValue.startsWith("http://")) {
                    endpoint.error = "请输入有效的 HTTP(S) API 地址"
                    return@setOnClickListener
                }
                if (modelValue.isBlank()) {
                    model.error = "请输入模型名称"
                    return@setOnClickListener
                }
                if (keyValue.isBlank()) {
                    apiKey.error = "请输入 API Key"
                    return@setOnClickListener
                }
                runCatching { store.save(ModelConfig(endpointValue, modelValue, keyValue)) }
                    .onSuccess {
                        Toast.makeText(this, "模型设置已安全保存", Toast.LENGTH_SHORT).show()
                        dialog.dismiss()
                    }
                    .onFailure { Toast.makeText(this, "保存失败：${it.message ?: "未知错误"}", Toast.LENGTH_LONG).show() }
            }
        }
        dialog.show()
    }

}
