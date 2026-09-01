import 'dart:convert';

import 'models.dart';

/// Splits a unified patch into independently reviewable hunks without
/// applying them, and rebuilds a full `apply_patch` from approved hunks.
/// Ported from Kotlin `DiffHunkApproval.kt` with `dart:convert` replacing
/// the hand-rolled JSON string parser.
abstract final class DiffHunkApproval {
  static List<ToolCall> expand(ToolCall call) {
    if (call.name != 'apply_patch') return [call];
    final args = _parseArguments(call.argumentsJson);
    final path = args?['path'];
    final patch = args?['patch'];
    if (path is! String || path.isEmpty || patch is! String || patch.isEmpty) {
      return [call];
    }
    final lines = patch.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final headers = <int>[
      for (var i = 0; i < lines.length; i++)
        if (lines[i].startsWith('@@ ')) i,
    ];
    if (headers.isEmpty) return [call];
    return [
      for (var index = 0; index < headers.length; index++)
        () {
          final start = headers[index];
          final end = index + 1 < headers.length ? headers[index + 1] : lines.length;
          final hunk = lines.sublist(start, end).join('\n').trimRight();
          return ToolCall(
            id: '${call.id}:hunk-${index + 1}',
            name: 'apply_patch_hunk',
            argumentsJson: jsonEncode({
              'path': path,
              'hunk_index': index + 1,
              'hunk_count': headers.length,
              'hunk': hunk,
            }),
          );
        }(),
    ];
  }

  /// Rebuilds a full apply_patch invocation from the hunks a user approved.
  static ToolCall collapse(List<ToolCall> approvedHunks) {
    if (approvedHunks.isEmpty) {
      throw ArgumentError('At least one approved hunk is required');
    }
    if (approvedHunks.any((h) => h.name != 'apply_patch_hunk')) {
      throw ArgumentError('Only apply_patch hunks can be collapsed');
    }
    String? pathOf(ToolCall call) => _parseArguments(call.argumentsJson)?['path'] as String?;
    final path = pathOf(approvedHunks.first);
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError('Approved hunk is missing a path');
    }
    if (approvedHunks.any((h) => pathOf(h) != path)) {
      throw ArgumentError('Approved hunks must belong to one file');
    }
    final ordered = [...approvedHunks]..sort((a, b) {
        final aIndex =
            (_parseArguments(a.argumentsJson)?['hunk_index'] as num?)?.toInt() ??
                0x7fffffff;
        final bIndex =
            (_parseArguments(b.argumentsJson)?['hunk_index'] as num?)?.toInt() ??
                0x7fffffff;
        return aIndex.compareTo(bIndex);
      });
    final patch = ordered
        .map((h) => _parseArguments(h.argumentsJson)?['hunk'] as String? ?? '')
        .join('\n');
    return ToolCall(
      id: approvedHunks.first.id.split(':hunk-').first,
      name: 'apply_patch',
      argumentsJson: jsonEncode({'path': path, 'patch': patch}),
    );
  }

  static Map<String, dynamic>? _parseArguments(String argumentsJson) {
    try {
      final decoded = jsonDecode(argumentsJson);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
