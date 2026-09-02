import '../tools/workspace.dart';
import 'git_manager.dart';

/// A point-in-time content copy of the workspace, taken before the agent
/// starts mutating files. Pure [Workspace] data, so it survives the same
/// storage path on SAF Android and desktop.
class SandboxSession {
  const SandboxSession({
    required this.id,
    required this.createdAt,
    required this.files,
  });

  final String id;
  final DateTime createdAt;
  final Map<String, String> files;

  int get fileCount => files.length;
}

/// What a rollback changed.
class RollbackReport {
  const RollbackReport({
    required this.restored,
    required this.removed,
    required this.failed,
  });

  /// Files that existed in the session and were rewritten to their
  /// original content.
  final List<String> restored;

  /// Files created after the session that were deleted.
  final List<String> removed;

  /// Restores that could not be completed (missing session content).
  final List<String> failed;

  bool get isEmpty => restored.isEmpty && removed.isEmpty && failed.isEmpty;

  int get changeCount => restored.length + removed.length;

  @override
  String toString() =>
      'RollbackReport(restored: ${restored.length}, removed: ${removed.length},'
      ' failed: ${failed.length})';
}

/// The Shelly safety net (V2.0 PHASE 05): before the agent works, capture
/// the whole workspace content; if anything goes wrong, roll every file
/// back to the session state. Complements [GitManager]: git handles
/// history where a git binary exists, the sandbox guarantees a recovery
/// point everywhere — including SAF-only Android workspaces.
class GitSandbox {
  GitSandbox(this._workspace, {String Function()? idFactory})
      : _idFactory = idFactory ?? _defaultId;

  final Workspace _workspace;
  final String Function() _idFactory;

  static String _defaultId() =>
      'sandbox-${DateTime.now().millisecondsSinceEpoch}';

  /// Captures every readable file in the workspace.
  Future<SandboxSession> open() async {
    final files = <String, String>{};
    for (final path in await _workspace.listFiles()) {
      final content = await _workspace.readFile(path);
      if (content != null) files[path] = content;
    }
    return SandboxSession(
      id: _idFactory(),
      createdAt: DateTime.now(),
      files: files,
    );
  }

  /// Restores the workspace to [session]: overwrites modified/deleted
  /// files with their original content and deletes files created after
  /// the session was captured.
  Future<RollbackReport> restore(SandboxSession session) async {
    final restored = <String>[];
    final removed = <String>[];
    final failed = <String>[];

    for (final entry in session.files.entries) {
      final current = await _workspace.readFile(entry.key);
      if (current != entry.value) {
        try {
          await _workspace.writeFile(entry.key, entry.value);
          restored.add(entry.key);
        } catch (_) {
          failed.add(entry.key);
        }
      }
    }
    for (final path in await _workspace.listFiles()) {
      if (!session.files.containsKey(path)) {
        try {
          if (await _workspace.deleteFile(path)) removed.add(path);
        } catch (_) {
          failed.add(path);
        }
      }
    }
    return RollbackReport(
      restored: restored,
      removed: removed,
      failed: failed,
    );
  }
}
