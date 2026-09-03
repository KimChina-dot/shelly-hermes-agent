package dev.shelly.hermes

import android.content.Context
import java.io.File
import java.security.MessageDigest

/**
 * App-private, write-before-apply snapshots keyed by SAF logical path.
 * Enables the model to roll back files after a bad patch without touching the
 * user's current content until restore is requested.
 */
class WorkspaceBackupStore(context: Context) {
    private val rootDir = File(context.filesDir, "workspace-backups").apply { mkdirs() }.absoluteFile

    fun save(logicalPath: String, content: String) {
        val target = File(rootDir, hash(logicalPath))
        File(target.parentFile, "${target.name}.tmp").writeText(content, Charsets.UTF_8)
        runCatching { target.delete() }
        if (!File(target.parentFile, "${target.name}.tmp").renameTo(target)) {
            target.writeText(content, Charsets.UTF_8)
        }
    }

    fun restore(logicalPath: String): String? {
        val target = File(rootDir, hash(logicalPath))
        return if (target.exists()) target.readText(Charsets.UTF_8) else null
    }

    fun clear(logicalPath: String) {
        File(rootDir, hash(logicalPath)).delete()
    }

    private fun hash(path: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(LogicalPath.validate(path).toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }
}
