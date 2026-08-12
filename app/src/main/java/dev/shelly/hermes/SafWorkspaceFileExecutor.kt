package dev.shelly.hermes

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.nio.charset.StandardCharsets
import java.util.Locale

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

    /** Recursively lists a bounded view of the workspace, excluding generated/vendor trees. */
    fun listFiles(path: String? = null, maxResults: Int = DEFAULT_LIST_LIMIT): ListingResult {
        require(maxResults in 1..MAX_LIST_LIMIT) { "List result limit must be between 1 and $MAX_LIST_LIMIT" }
        val limit = maxResults
        val basePath = path?.takeIf { it.isNotBlank() }?.let(LogicalPath::validate)
        val baseDocument = if (basePath == null) {
            rootDocumentUri()
        } else {
            resolveExisting(basePath)
                ?: throw FileNotFoundException("Workspace directory does not exist: $basePath")
        }
        require(queryMimeType(baseDocument) == DocumentsContract.Document.MIME_TYPE_DIR) {
            "Workspace path is not a directory: ${basePath.orEmpty()}"
        }
        val entries = mutableListOf<WorkspaceEntry>()
        var truncated = false

        fun walk(parent: Uri, parentPath: String, depth: Int) {
            if (entries.size >= limit || depth > MAX_WALK_DEPTH) {
                truncated = true
                return
            }
            for (child in queryChildren(parent).sortedBy { it.name.lowercase(Locale.ROOT) }) {
                if (entries.size >= limit) {
                    truncated = true
                    return
                }
                if (!isSafeChildName(child.name) || child.isDirectory && isIgnoredDirectory(child.name)) continue
                val childPath = if (parentPath.isEmpty()) child.name else "$parentPath/${child.name}"
                LogicalPath.validate(childPath)
                entries += WorkspaceEntry(childPath, child.isDirectory, child.size)
                if (child.isDirectory) walk(child.uri, childPath, depth + 1)
            }
        }

        walk(baseDocument, basePath.orEmpty(), 0)
        return ListingResult(entries, truncated)
    }

    /** Searches UTF-8 text files without allowing an unbounded provider traversal. */
    fun searchFiles(
        query: String,
        path: String? = null,
        maxResults: Int = DEFAULT_SEARCH_LIMIT,
    ): SearchResult {
        require(query.isNotBlank()) { "Search query must not be blank" }
        require(query.length <= MAX_QUERY_CHARS) { "Search query is too long" }
        require(maxResults in 1..MAX_SEARCH_LIMIT) { "Search result limit must be between 1 and $MAX_SEARCH_LIMIT" }
        val limit = maxResults
        val listing = listFiles(path, MAX_SEARCH_FILES)
        val matches = mutableListOf<WorkspaceSearchMatch>()
        var truncated = listing.truncated
        for (entry in listing.entries) {
            if (matches.size >= limit) {
                truncated = true
                break
            }
            if (entry.isDirectory || !looksLikeTextFile(entry.path) || (entry.size ?: 0L) > MAX_SEARCH_FILE_BYTES) continue
            val content = readTextLimited(entry.path, MAX_SEARCH_FILE_BYTES.toInt()) ?: continue
            if (content.truncated) {
                // A match after this boundary cannot be ruled out.
                truncated = true
            }
            content.text.lineSequence().forEachIndexed { index, line ->
                if (matches.size >= limit) {
                    truncated = true
                    return@forEachIndexed
                }
                val column = line.indexOf(query, ignoreCase = true)
                if (column >= 0) {
                    matches += WorkspaceSearchMatch(
                        path = entry.path,
                        line = index + 1,
                        column = column + 1,
                        preview = line.take(MAX_PREVIEW_CHARS),
                    )
                }
            }
        }
        return SearchResult(matches, truncated)
    }

    /** Applies a unified diff only when every old/context line still matches exactly. */
    fun applyPatch(path: String, patch: String): PatchResult {
        ensureWritePermission()
        require(patch.length <= MAX_PATCH_CHARS) { "Patch exceeds the write limit" }
        val logicalPath = LogicalPath.validate(path)
        val document = resolveExisting(logicalPath)
            ?: throw FileNotFoundException("Workspace file does not exist: $logicalPath")
        require(queryMimeType(document) != DocumentsContract.Document.MIME_TYPE_DIR) {
            "Workspace path is a directory: $logicalPath"
        }
        val original = readText(logicalPath)
            ?: throw FileNotFoundException("Workspace file does not exist: $logicalPath")
        val updated = UnifiedPatch.apply(original, patch)
        require(updated.text.length <= MAX_PATCHED_FILE_CHARS) { "Patched file exceeds the write limit" }
        write(document, updated.text, "rwt")
        return PatchResult(updated.hunksApplied, updated.text.length)
    }

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

    private fun queryChildren(parentDocumentUri: Uri): List<DocumentChild> {
        val parentId = DocumentsContract.getDocumentId(parentDocumentUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(rootTreeUri, parentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        return buildList {
            resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIndex = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameIndex) ?: continue
                    val mime = cursor.getString(mimeIndex)
                    add(
                        DocumentChild(
                            uri = DocumentsContract.buildDocumentUriUsingTree(rootTreeUri, cursor.getString(idIndex)),
                            name = name,
                            isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
                            size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else null,
                        ),
                    )
                }
            }
        }
    }

    private fun readTextLimited(path: String, maxBytes: Int): LimitedText? {
        val document = resolveExisting(path) ?: return null
        resolver.openInputStream(document)?.use { input ->
            val buffer = ByteArray(maxBytes + 1)
            var offset = 0
            while (offset < buffer.size) {
                val count = input.read(buffer, offset, buffer.size - offset)
                if (count < 0) break
                offset += count
            }
            val truncated = offset > maxBytes
            val length = offset.coerceAtMost(maxBytes)
            return LimitedText(String(buffer, 0, length, StandardCharsets.UTF_8), truncated)
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

    data class WorkspaceEntry(val path: String, val isDirectory: Boolean, val size: Long?)
    data class ListingResult(val entries: List<WorkspaceEntry>, val truncated: Boolean)
    data class WorkspaceSearchMatch(val path: String, val line: Int, val column: Int, val preview: String)
    data class SearchResult(val matches: List<WorkspaceSearchMatch>, val truncated: Boolean)
    data class PatchResult(val hunksApplied: Int, val charactersWritten: Int)

    private data class DocumentChild(val uri: Uri, val name: String, val isDirectory: Boolean, val size: Long?)
    private data class LimitedText(val text: String, val truncated: Boolean)

    private fun isSafeChildName(name: String): Boolean = runCatching {
        LogicalPath.validate(name)
        true
    }.getOrDefault(false)

    private fun isIgnoredDirectory(name: String): Boolean = name.lowercase(Locale.ROOT) in IGNORED_DIRECTORIES

    private fun looksLikeTextFile(path: String): Boolean {
        val name = path.substringAfterLast('/').lowercase(Locale.ROOT)
        if (name in TEXT_FILE_NAMES) return true
        val extension = name.substringAfterLast('.', missingDelimiterValue = "")
        return extension in TEXT_EXTENSIONS
    }

    companion object {
        const val DEFAULT_LIST_LIMIT = 200
        const val DEFAULT_SEARCH_LIMIT = 50
        const val MAX_LIST_LIMIT = 500
        const val MAX_SEARCH_LIMIT = 100
        // listFiles enforces MAX_LIST_LIMIT, so search must use the same bounded traversal ceiling.
        private const val MAX_SEARCH_FILES = MAX_LIST_LIMIT
        private const val MAX_WALK_DEPTH = 32
        private const val MAX_QUERY_CHARS = 512
        private const val MAX_SEARCH_FILE_BYTES = 1_000_000L
        private const val MAX_PREVIEW_CHARS = 500
        private const val MAX_PATCH_CHARS = 1_000_000
        private const val MAX_PATCHED_FILE_CHARS = 2_000_000
        private val IGNORED_DIRECTORIES = setOf(
            ".git", ".gradle", ".idea", ".next", ".turbo", "build", "dist", "node_modules", "out", "target",
        )
        private val TEXT_FILE_NAMES = setOf(
            "dockerfile", "gradle.properties", "makefile", "readme", "license",
        )
        private val TEXT_EXTENSIONS = setOf(
            "c", "cc", "cpp", "css", "csv", "go", "gradle", "h", "hpp", "html", "java", "js", "json",
            "jsx", "kt", "kts", "md", "properties", "py", "rb", "rs", "sh", "sql", "svg", "toml", "ts",
            "tsx", "txt", "xml", "yaml", "yml",
        )
    }
}

/** Pure unified-diff engine kept Android-free so stale-patch behavior is JVM-testable. */
internal object UnifiedPatch {
    data class Applied(val text: String, val hunksApplied: Int)

    fun apply(original: String, rawPatch: String): Applied {
        require(rawPatch.isNotBlank()) { "Patch must not be blank" }
        val patchLines = rawPatch.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val originalHadNewline = original.endsWith("\n")
        val source = original.replace("\r\n", "\n").replace('\r', '\n').let {
            if (it.endsWith("\n")) it.dropLast(1).split('\n') else if (it.isEmpty()) emptyList() else it.split('\n')
        }
        val output = mutableListOf<String>()
        var sourceCursor = 0
        var patchCursor = patchLines.indexOfFirst { it.startsWith("@@ ") }
        require(patchCursor >= 0) { "Patch contains no unified-diff hunks" }
        var hunks = 0
        var noFinalNewline = false

        while (patchCursor < patchLines.size) {
            val header = patchLines[patchCursor]
            if (header.isEmpty()) {
                patchCursor++
                continue
            }
            val match = HUNK_HEADER.matchEntire(header)
                ?: throw IllegalArgumentException("Unexpected patch line outside a hunk: $header")
            val oldStart = match.groupValues[1].toInt()
            val oldCount = match.groupValues[2].ifEmpty { "1" }.toInt()
            val newCount = match.groupValues[4].ifEmpty { "1" }.toInt()
            val hunkStart = if (oldStart == 0) 0 else oldStart - 1
            require(hunkStart >= sourceCursor && hunkStart <= source.size) { "Patch hunks overlap or target an invalid line" }
            output += source.subList(sourceCursor, hunkStart)
            sourceCursor = hunkStart
            patchCursor++
            var consumedOld = 0
            var producedNew = 0
            var lastOperation: Char? = null
            while (patchCursor < patchLines.size && !patchLines[patchCursor].startsWith("@@ ")) {
                val line = patchLines[patchCursor]
                if (line.isEmpty() && patchCursor == patchLines.lastIndex) {
                    patchCursor++
                    break
                }
                if (line.startsWith("\\ No newline at end of file")) {
                    if (lastOperation == '+') noFinalNewline = true
                    patchCursor++
                    continue
                }
                if (line.startsWith("*** End Patch") || line.startsWith("--- ") || line.startsWith("+++ ")) break
                require(line.isNotEmpty()) { "Every hunk line must start with space, +, or -" }
                val operation = line[0]
                val value = line.substring(1)
                when (operation) {
                    ' ' -> {
                        require(source.getOrNull(sourceCursor) == value) { "Patch context is stale at source line ${sourceCursor + 1}" }
                        output += value
                        sourceCursor++
                        consumedOld++
                        producedNew++
                    }
                    '-' -> {
                        require(source.getOrNull(sourceCursor) == value) { "Patch removal is stale at source line ${sourceCursor + 1}" }
                        sourceCursor++
                        consumedOld++
                    }
                    '+' -> {
                        output += value
                        producedNew++
                    }
                    else -> throw IllegalArgumentException("Invalid hunk operation: $operation")
                }
                lastOperation = operation
                patchCursor++
            }
            require(consumedOld == oldCount) { "Hunk old-line count mismatch: expected $oldCount, got $consumedOld" }
            require(producedNew == newCount) { "Hunk new-line count mismatch: expected $newCount, got $producedNew" }
            hunks++
            while (patchCursor < patchLines.size && !patchLines[patchCursor].startsWith("@@ ")) {
                val line = patchLines[patchCursor]
                if (line.isNotEmpty() && !line.startsWith("*** End Patch")) {
                    throw IllegalArgumentException("Unexpected patch line outside a hunk: $line")
                }
                patchCursor++
            }
        }
        output += source.drop(sourceCursor)
        val trailingNewline = originalHadNewline && !noFinalNewline
        return Applied(output.joinToString("\n") + if (trailingNewline) "\n" else "", hunks)
    }

    private val HUNK_HEADER = Regex("^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@.*$")
}
