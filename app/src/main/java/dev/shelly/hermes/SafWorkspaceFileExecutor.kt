package dev.shelly.hermes

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets

/**
 * Android-only SAF adapter. All paths are logical paths resolved below the
 * persisted document-tree root. Raw content URIs and filesystem paths are
 * never accepted from callers.
 */
class SafWorkspaceFileExecutor(
    private val resolver: ContentResolver,
    private val rootTreeUri: Uri,
) {
    constructor(context: Context, rootTreeUri: Uri) : this(context.contentResolver, rootTreeUri)

    init {
        require(DocumentsContract.isTreeUri(rootTreeUri)) { "Workspace root must be a SAF tree URI" }
        require(hasPersistedReadPermission()) { "Workspace root is not covered by a persisted read grant" }
    }

    fun readText(path: String): String? {
        val document = resolveExisting(path) ?: return null
        resolver.openInputStream(document)?.use { input ->
            return input.readBytes().toString(StandardCharsets.UTF_8)
        }
        throw FileNotFoundException("Unable to open workspace file: ${LogicalPath.validate(path)}")
    }

    fun exists(path: String): Boolean = resolveExisting(path) != null

    fun createText(path: String, text: String) {
        ensureWritePermission()
        val logicalPath = LogicalPath.validate(path)
        require(resolveExisting(logicalPath) == null) { "Workspace file already exists: $logicalPath" }
        val target = createFile(logicalPath)
        write(target, text, "wt")
    }

    fun overwriteText(path: String, text: String) {
        ensureWritePermission()
        val logicalPath = LogicalPath.validate(path)
        val target = resolveExisting(logicalPath) ?: createFile(logicalPath)
        write(target, text, "rwt")
    }

    fun appendText(path: String, text: String) {
        ensureWritePermission()
        val logicalPath = LogicalPath.validate(path)
        val target = resolveExisting(logicalPath) ?: createFile(logicalPath)
        write(target, text, "wa")
    }

    private fun resolveExisting(path: String): Uri? {
        val segments = LogicalPath.validate(path).split('/')
        var current = rootDocumentUri()
        for (segment in segments) {
            current = findChild(current, segment) ?: return null
        }
        return current
    }

    private fun createFile(path: String): Uri {
        val segments = path.split('/')
        var parent = rootDocumentUri()
        for (directory in segments.dropLast(1)) {
            val existing = findChild(parent, directory)
            parent = if (existing != null) {
                require(queryMimeType(existing) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    "Workspace path segment is not a directory: $directory"
                }
                existing
            } else {
                DocumentsContract.createDocument(
                    resolver,
                    parent,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    directory,
                ) ?: throw FileNotFoundException("Unable to create workspace directory: $directory")
            }
        }
        return DocumentsContract.createDocument(
            resolver,
            parent,
            "text/plain",
            segments.last(),
        ) ?: throw FileNotFoundException("Unable to create workspace file: $path")
    }

    private fun findChild(parentDocumentUri: Uri, displayName: String): Uri? {
        val parentId = DocumentsContract.getDocumentId(parentDocumentUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootTreeUri, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                if (cursor.getString(nameIndex) == displayName) {
                    return DocumentsContract.buildDocumentUriUsingTree(rootTreeUri, cursor.getString(idIndex))
                }
            }
        }
        return null
    }

    private fun queryMimeType(documentUri: Uri): String? {
        val projection = arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE)
        resolver.query(documentUri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return null
    }

    private fun write(documentUri: Uri, text: String, mode: String) {
        resolver.openOutputStream(documentUri, mode)?.use { output ->
            output.write(text.toByteArray(StandardCharsets.UTF_8))
            output.flush()
            return
        }
        throw FileNotFoundException("Unable to open workspace file for writing")
    }

    private fun rootDocumentUri(): Uri = DocumentsContract.buildDocumentUriUsingTree(
        rootTreeUri,
        DocumentsContract.getTreeDocumentId(rootTreeUri),
    )

    private fun hasPersistedReadPermission(): Boolean = resolver.persistedUriPermissions.any {
        it.uri == rootTreeUri && it.isReadPermission
    }

    private fun ensureWritePermission() {
        require(resolver.persistedUriPermissions.any {
            it.uri == rootTreeUri && it.isWritePermission
        }) { "Workspace root is not covered by a persisted write grant" }
    }
}
