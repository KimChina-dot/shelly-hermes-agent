import 'dart:convert';

/// Workspace storage abstraction. On Android this is backed by SAF through a
/// platform bridge; on the dev/web harness by [MemoryWorkspace].
abstract interface class Workspace {
  /// Returns the file content, or null when the file does not exist.
  Future<String?> readFile(String path);

  /// Creates or overwrites a file.
  Future<void> writeFile(String path, String content);

  Future<bool> exists(String path);

  /// Lists files whose path contains [prefix] (empty = all), sorted.
  Future<List<String>> listFiles([String prefix]);

  /// Returns paths whose name or content contains [query] (case-insensitive).
  Future<List<String>> searchFiles(String query);
}

/// In-memory workspace used by tests and the web development harness.
class MemoryWorkspace implements Workspace {
  final Map<String, String> files;

  MemoryWorkspace([Map<String, String>? initial])
      : files = initial != null ? Map.of(initial) : <String, String>{};

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  Future<void> writeFile(String path, String content) async {
    files[path] = content;
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<List<String>> listFiles([String prefix = '']) async {
    final paths = files.keys.where((p) => p.contains(prefix)).toList()..sort();
    return paths;
  }

  @override
  Future<List<String>> searchFiles(String query) async {
    if (query.isEmpty) return const [];
    final needle = query.toLowerCase();
    final matches = <String>[];
    for (final entry in Map.of(files).entries) {
      if (entry.key.toLowerCase().contains(needle) ||
          entry.value.toLowerCase().contains(needle)) {
        matches.add(entry.key);
      }
    }
    matches.sort();
    return matches;
  }
}

/// Applies a Shelly-style unified patch (a sequence of `@@` hunks whose lines
/// are ` ` context, `-` removals and `+` additions) to [original]. Hunk
/// headers carry no semantics beyond separation. Throws [PatchException] when
/// a hunk's context does not match the file, leaving the file untouched.
String applyPatchToContent(String original, String patch) {
  final hunks = parseHunks(patch);
  if (hunks.isEmpty) {
    throw const PatchException('patch contains no hunks');
  }
  final lines = original.isEmpty ? <String>[] : original.split('\n');
  // Preserve a trailing-newline marker: "a\nb\n" splits to [a, b, ''].
  final endsWithNewline = original.endsWith('\n');
  var searchFrom = 0;
  for (final hunk in hunks) {
    final oldLines = [
      for (final line in hunk)
        if (!line.startsWith('+')) line.length > 1 ? line.substring(1) : '',
    ];
    final newLines = [
      for (final line in hunk)
        if (!line.startsWith('-')) line.length > 1 ? line.substring(1) : '',
    ];
    final at = _findSubsequence(lines, oldLines, searchFrom);
    if (at < 0) {
      throw PatchException(
        'hunk context not found at or after line ${searchFrom + 1}',
      );
    }
    lines.replaceRange(at, at + oldLines.length, newLines);
    searchFrom = at + newLines.length;
  }
  final joined = lines.join('\n');
  if (!endsWithNewline && joined.endsWith('\n')) {
    return joined.substring(0, joined.length - 1);
  }
  if (endsWithNewline && !joined.endsWith('\n') && joined.isNotEmpty) {
    return '$joined\n';
  }
  return joined;
}

class PatchException implements Exception {
  const PatchException(this.message);

  final String message;

  @override
  String toString() => 'PatchException: $message';
}

final RegExp _hunkHeader = RegExp(r'^@@');

List<List<String>> parseHunks(String patch) {
  final hunks = <List<String>>[];
  var current = <String>[];
  for (final rawLine in patch.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final line = rawLine.trimRight();
    if (_hunkHeader.hasMatch(line)) {
      if (current.isNotEmpty) hunks.add(current);
      current = <String>[];
      continue;
    }
    if (line.startsWith(' ') || line.startsWith('-') || line.startsWith('+')) {
      current.add(line);
    }
    // Anything else (e.g. "--- / +++" banners) is ignored.
  }
  if (current.isNotEmpty) hunks.add(current);
  return hunks;
}

int _findSubsequence(List<String> haystack, List<String> needle, int from) {
  if (needle.isEmpty) return from;
  for (var i = from; i + needle.length <= haystack.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return i;
  }
  return -1;
}

/// Decodes tool-call arguments defensively; executors receive this map.
Map<String, dynamic> decodeArguments(String argumentsJson) {
  if (argumentsJson.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(argumentsJson);
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ToolArgumentsException('arguments must be a JSON object');
  } on FormatException {
    throw const ToolArgumentsException('arguments are not valid JSON');
  }
}

class ToolArgumentsException implements Exception {
  const ToolArgumentsException(this.message);

  final String message;

  @override
  String toString() => 'ToolArgumentsException: $message';
}
