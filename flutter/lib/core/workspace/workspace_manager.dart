// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import 'dart:convert';

import '../tools/workspace.dart';
import 'project.dart';

/// Persistence port for the "current workspace" selection. Android persists
/// its SAF tree grant natively, so the default host wiring may pass an
/// in-memory store; desktop/web harnesses use this port to survive restarts.
abstract interface class WorkspaceStateStore {
  Future<void> saveRoot(String rootId);
  Future<String?> loadRoot();
}

/// Keeps the last bound root for the lifetime of the process.
class MemoryStateStore implements WorkspaceStateStore {
  String? _root;

  @override
  Future<void> saveRoot(String rootId) async => _root = rootId;

  @override
  Future<String?> loadRoot() async => _root;
}

/// Unified entry point for the Shelly execution side (V2.0 PHASE 03):
/// project detection (cached), workspace snapshots, and root persistence.
/// Everything runs through the [Workspace] abstraction, so behavior is
/// identical on the SAF bridge and in tests.
class WorkspaceManager {
  WorkspaceManager({
    required this.workspace,
    this.stateStore = const _NullStateStore(),
    ProjectDetector detector = const ProjectDetector(),
  }) : _detector = detector;

  final Workspace workspace;
  final WorkspaceStateStore stateStore;
  final ProjectDetector _detector;

  ProjectInfo? _cachedProject;

  /// Detects the project kind/name, memoized until [invalidateProject].
  Future<ProjectInfo> detectProject({bool force = false}) async {
    final cached = _cachedProject;
    if (!force && cached != null) return cached;
    final info = await _detector.detect(workspace);
    _cachedProject = info;
    return info;
  }

  /// Call after an external party may have changed the workspace layout.
  void invalidateProject() => _cachedProject = null;

  /// Persists the host-provided root identity (e.g. the SAF tree URI).
  Future<void> bindRoot(String rootId) => stateStore.saveRoot(rootId);

  /// Returns the persisted root identity, or null when never bound.
  Future<String?> restoreRoot() => stateStore.loadRoot();

  /// Captures path → content hash for every file in the workspace.
  /// PHASE 05's sandbox compares snapshots to scope a rollback.
  Future<WorkspaceSnapshot> snapshot() async {
    final paths = await workspace.listFiles();
    final hashes = <String, String>{};
    for (final path in paths) {
      final content = await workspace.readFile(path);
      if (content == null) continue;
      hashes[path] = _fnv1a64Hex(content);
    }
    return WorkspaceSnapshot(takenAt: DateTime.now(), hashes: hashes);
  }
}

/// Path → FNV-1a64 hex hashes captured at a point in time.
class WorkspaceSnapshot {
  const WorkspaceSnapshot({required this.takenAt, required this.hashes});

  final DateTime takenAt;
  final Map<String, String> hashes;

  WorkspaceSnapshotDiff diffTo(WorkspaceSnapshot other) {
    final added = [
      for (final entry in other.hashes.entries)
        if (!hashes.containsKey(entry.key)) entry.key,
    ];
    final removed = [
      for (final entry in hashes.entries)
        if (!other.hashes.containsKey(entry.key)) entry.key,
    ];
    final modified = [
      for (final entry in hashes.entries)
        if (other.hashes[entry.key] != null &&
            other.hashes[entry.key] != entry.value)
          entry.key,
    ];
    return WorkspaceSnapshotDiff(
      added: added,
      removed: removed,
      modified: modified,
    );
  }
}

class WorkspaceSnapshotDiff {
  const WorkspaceSnapshotDiff({
    required this.added,
    required this.removed,
    required this.modified,
  });

  final List<String> added;
  final List<String> removed;
  final List<String> modified;

  bool get isEmpty => added.isEmpty && removed.isEmpty && modified.isEmpty;

  int get changeCount => added.length + removed.length + modified.length;

  Map<String, dynamic> toJson() => {
        'added': added,
        'removed': removed,
        'modified': modified,
      };
}

/// FNV-1a over UTF-8 bytes, masked to 63 bits so the value stays a positive
/// signed 64-bit int — dependency-free and deterministic across runs and
/// isolates (unlike [Object.hash]).
String _fnv1a64Hex(String content) {
  const prime = 0x100000001b3;
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(content)) {
    hash ^= byte;
    hash = (hash * prime) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class _NullStateStore implements WorkspaceStateStore {
  const _NullStateStore();

  @override
  Future<void> saveRoot(String rootId) async {}

  @override
  Future<String?> loadRoot() async => null;
}
