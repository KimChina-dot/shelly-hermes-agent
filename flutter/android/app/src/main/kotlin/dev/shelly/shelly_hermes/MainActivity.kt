package dev.shelly.shelly_hermes

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingTreePick: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerWorkspaceChannel(flutterEngine)
        registerSecureStoreChannel(flutterEngine)
        registerTaskServiceChannel(flutterEngine)
    }

    // ------------------------------------------------------------------
    // Workspace over SAF: one user-picked tree, remembered across runs.
    // ------------------------------------------------------------------
    private fun registerWorkspaceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.shelly/workspace")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        intent.addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                        pendingTreePick = result
                        startActivityForResult(intent, REQUEST_PICK_TREE)
                    }
                    "hasDirectory" -> result.success(treeUriPref() != null)
                    "forgetDirectory" -> {
                        prefs().edit().remove(PREF_TREE_URI).apply()
                        result.success(null)
                    }
                    "readFile" -> readFile(call.arguments as String, result)
                    "writeFile" -> writeFile(
                        call.argument<String>("path")!!,
                        call.argument<String>("content")!!,
                        result,
                    )
                    "deleteFile" -> deleteFile(call.arguments as String, result)
                    "listFiles" -> listFiles(call.arguments as String?, result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_TREE) return
        val pending = pendingTreePick
        pendingTreePick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending?.success(null)
            return
        }
        contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
        prefs().edit().putString(PREF_TREE_URI, uri.toString()).apply()
        pending?.success(uri.toString())
    }

    private fun prefs() = getSharedPreferences("shelly_native", MODE_PRIVATE)

    private fun treeUriPref(): Uri? =
        prefs().getString(PREF_TREE_URI, null)?.let(Uri::parse)

    private fun fail(result: MethodChannel.Result, message: String) {
        result.error("workspace", message, null)
    }

    /** Walks "a/b/c" segments from the tree root, returning the document Uri. */
    private fun resolveDocument(path: String): Uri? {
        val tree = treeUriPref() ?: throw IllegalStateException("no workspace directory picked")
        var documentUri = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree),
        )
        val trimmed = path.trim('/')
        if (trimmed.isEmpty()) return documentUri
        for (segment in trimmed.split('/')) {
            val child = findChild(documentUri, segment) ?: return null
            documentUri = child
        }
        return documentUri
    }

    private fun findChild(parent: Uri, displayName: String): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent, DocumentsContract.getDocumentId(parent),
        )
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == displayName) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        treeUriPref()!!, cursor.getString(0),
                    )
                }
            }
        }
        return null
    }

    private fun readFile(path: String, result: MethodChannel.Result) {
        try {
            val uri = resolveDocument(path)
            if (uri == null) {
                result.success(null)
                return
            }
            val text = contentResolver.openInputStream(uri)?.use { input ->
                input.readBytes().toString(Charsets.UTF_8)
            }
            result.success(text)
        } catch (e: Exception) {
            fail(result, e.message ?: "read failed")
        }
    }

    private fun writeFile(path: String, content: String, result: MethodChannel.Result) {
        try {
            val tree = treeUriPref() ?: throw IllegalStateException("no workspace directory picked")
            var parentUri = DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree),
            )
            val segments = path.trim('/').split('/').filter { it.isNotEmpty() }
            for (i in 0 until segments.size - 1) {
                parentUri = findChild(parentUri, segments[i])
                    ?: DocumentsContract.createDocument(
                        contentResolver, parentUri,
                        DocumentsContract.Document.MIME_TYPE_DIR, segments[i],
                    )
                    ?: throw IllegalStateException("cannot create folder ${segments[i]}")
            }
            val name = segments.last()
            var docUri = findChild(parentUri, name)
            if (docUri == null) {
                docUri = DocumentsContract.createDocument(
                    contentResolver, parentUri, "application/octet-stream", name,
                ) ?: throw IllegalStateException("cannot create file $name")
            }
            contentResolver.openOutputStream(docUri, "wt")?.use { output ->
                output.write(content.toByteArray(Charsets.UTF_8))
            } ?: throw IllegalStateException("cannot open output for $name")
            result.success(null)
        } catch (e: Exception) {
            fail(result, e.message ?: "write failed")
        }
    }

    private fun deleteFile(path: String, result: MethodChannel.Result) {
        try {
            val uri = resolveDocument(path)
            if (uri == null) {
                result.success(false)
                return
            }
            result.success(DocumentsContract.deleteDocument(contentResolver, uri))
        } catch (e: Exception) {
            fail(result, e.message ?: "delete failed")
        }
    }

    private fun listFiles(prefix: String?, result: MethodChannel.Result) {
        try {
            val names = mutableListOf<String>()
            val root = treeUriPref()
                ?: throw IllegalStateException("no workspace directory picked")
            var current = DocumentsContract.buildDocumentUriUsingTree(
                root, DocumentsContract.getTreeDocumentId(root),
            )
            val segments = (prefix ?: "").trim('/').split('/').filter { it.isNotEmpty() }
            for (segment in segments) {
                current = findChild(current, segment)
                    ?: throw IllegalStateException("folder not found: $segment")
            }
            collectNames(current, "", names)
            result.success(names)
        } catch (e: Exception) {
            fail(result, e.message ?: "list failed")
        }
    }

    private fun findChildId(folder: Uri, displayName: String): String? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            folder, DocumentsContract.getDocumentId(folder),
        )
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == displayName) return cursor.getString(0)
            }
        }
        return null
    }

    private fun collectNames(folder: Uri, prefix: String, names: MutableList<String>) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            folder, DocumentsContract.getDocumentId(folder),
        )
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1)
                if (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val childFolder = DocumentsContract.buildDocumentUriUsingTree(
                        treeUriPref()!!, cursor.getString(0),
                    )
                    collectNames(childFolder, "$prefix$name/", names)
                } else {
                    names.add("$prefix$name")
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Secure storage: AndroidKeyStore-backed, see SecureStore.kt.
    // ------------------------------------------------------------------
    private fun registerSecureStoreChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.shelly/secure_store")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> result.success(SecureStore.read(this, call.arguments as String))
                        "write" -> {
                            SecureStore.write(
                                this,
                                call.argument<String>("key")!!,
                                call.argument<String>("value")!!,
                            )
                            result.success(null)
                        }
                        "delete" -> {
                            SecureStore.delete(this, call.arguments as String)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("secure_store", e.message, null)
                }
            }
    }

    // ------------------------------------------------------------------
    // Foreground service: keeps a visible notification while a task runs.
    // ------------------------------------------------------------------
    private fun registerTaskServiceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.shelly/task_service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        TaskForegroundService.start(this)
                        result.success(null)
                    }
                    "stop" -> {
                        TaskForegroundService.stop(this)
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        TaskForegroundService.requestPermission(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val PREF_TREE_URI = "workspace.tree"
        private const val REQUEST_PICK_TREE = 4701
    }
}
