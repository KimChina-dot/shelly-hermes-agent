import '../tools/workspace.dart';

/// What kind of project lives in a workspace, resolved with the priority
/// Flutter > Android > Git > plain (V2.0 roadmap PHASE 03). Git is also
/// reported orthogonally as [ProjectInfo.isGitRepo].
enum ProjectKind { flutter, android, git, plain }

/// Detection result for the workspace the agent is about to operate on.
/// Hermes (per-project knowledge) and the Git sandbox both key off this.
class ProjectInfo {
  const ProjectInfo({
    required this.kind,
    required this.name,
    required this.isGitRepo,
    required this.markers,
  });

  final ProjectKind kind;
  final String name;
  final bool isGitRepo;

  /// The workspace paths whose existence triggered the detection, in check
  /// order — useful for diagnostics and for explaining a detection result.
  final List<String> markers;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'name': name,
        'isGitRepo': isGitRepo,
        'markers': markers,
      };

  static ProjectInfo fromJson(Map<String, dynamic> json) => ProjectInfo(
        kind: ProjectKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => ProjectKind.plain,
        ),
        name: json['name'] as String? ?? 'project',
        isGitRepo: json['isGitRepo'] as bool? ?? false,
        markers: [
          for (final m in json['markers'] as List? ?? const []) m as String,
        ],
      );
}

/// Pure detection over the [Workspace] abstraction: no dart:io, so it works
/// identically against the SAF bridge on Android and the in-memory harness
/// in tests.
class ProjectDetector {
  const ProjectDetector();

  static const _flutterMarkers = ['pubspec.yaml'];
  static const _androidMarkers = [
    'app/build.gradle',
    'app/build.gradle.kts',
    'build.gradle',
    'build.gradle.kts',
    'settings.gradle',
    'settings.gradle.kts',
  ];

  /// `.git/HEAD` is the authoritative marker; `.gitignore` is a weak
  /// fallback for hosts whose document provider does not walk dot-directories.
  static const _gitMarkers = ['.git/HEAD', '.gitignore'];

  Future<ProjectInfo> detect(Workspace workspace) async {
    final hit = <String>[];
    Future<bool> probe(String path) async {
      final found = await workspace.exists(path);
      if (found) hit.add(path);
      return found;
    }

    var isGitRepo = false;
    for (final marker in _gitMarkers) {
      if (await probe(marker)) {
        isGitRepo = true;
        break;
      }
    }

    for (final marker in _flutterMarkers) {
      if (await probe(marker)) {
        final name =
            await _pubspecName(workspace) ?? _fallbackName(workspace);
        return ProjectInfo(
          kind: ProjectKind.flutter,
          name: name,
          isGitRepo: isGitRepo,
          markers: List.unmodifiable(hit),
        );
      }
    }

    for (final marker in _androidMarkers) {
      if (await probe(marker)) {
        final name = await _androidName(workspace) ?? _fallbackName(workspace);
        return ProjectInfo(
          kind: ProjectKind.android,
          name: name,
          isGitRepo: isGitRepo,
          markers: List.unmodifiable(hit),
        );
      }
    }

    if (isGitRepo) {
      return ProjectInfo(
        kind: ProjectKind.git,
        name: _fallbackName(workspace),
        isGitRepo: true,
        markers: List.unmodifiable(hit),
      );
    }

    return ProjectInfo(
      kind: ProjectKind.plain,
      name: _fallbackName(workspace),
      isGitRepo: false,
      markers: const [],
    );
  }

  Future<String?> _pubspecName(Workspace workspace) async {
    final content = await workspace.readFile('pubspec.yaml');
    if (content == null) return null;
    final match = RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(content);
    return match?.group(1);
  }

  Future<String?> _androidName(Workspace workspace) async {
    for (final marker in _androidMarkers) {
      final content = await workspace.readFile(marker);
      if (content == null) continue;
      final match = RegExp(
        r'''applicationId\s+['"]([\w.]+)['"]''',
      ).firstMatch(content);
      if (match != null) return match.group(1);
      final namespace = RegExp(
        r'''namespace\s+['"]([\w.]+)['"]''',
      ).firstMatch(content);
      if (namespace != null) return namespace.group(1);
    }
    return null;
  }

  /// Workspace has no directory concept in the file API, so the human
  /// readable fallback stays generic; hosts that know the root display name
  /// override it at the UI layer.
  String _fallbackName(Workspace workspace) => 'project';
}
