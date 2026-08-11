package dev.shelly.hermes

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

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
        findViewById<TextView>(R.id.toolCapability).text = """
            read_file       读取 UTF-8 文本
            exists          检查文件是否存在
            create_file     创建新文件
            overwrite_file  创建或覆盖文件
            append_file     追加文本
        """.trimIndent()
        findViewById<TextView>(R.id.securityCapability).text =
            "所有写入操作都必须经过人工审批；工具不接受绝对路径、路径穿越或 shell 命令。"
    }
}
