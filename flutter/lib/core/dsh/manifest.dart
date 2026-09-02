import 'dart:convert';

/// DSH plugin manifest (V2.0 PHASE 11). Declarative, JSON, plain text.
class DshPermissions {
  static const workspaceRead = 'workspace.read';
  static const workspaceWrite = 'workspace.write';
  static const terminalExecute = 'terminal.execute';
  static const network = 'network';
  static const git = 'git';
  static const process = 'process';

  static const all = {
    workspaceRead,
    workspaceWrite,
    terminalExecute,
    network,
    git,
    process,
  };
}

/// One tool a plugin declares. For `shell`-runtime plugins the tool is
/// backed by a command template (`{arg}` placeholders are filled from the
/// call arguments); `dart`-runtime tools resolve against embedded plugins.
class DshToolDecl {
  const DshToolDecl({
    required this.name,
    required this.description,
    this.risk = 'medium',
    this.command,
  });

  final String name;
  final String description;
  final String risk;

  /// Shell command template for runtime=shell plugins.
  final String? command;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'risk': risk,
        if (command != null) 'command': command,
      };

  static DshToolDecl fromJson(Map<String, dynamic> json) => DshToolDecl(
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        risk: json['risk'] as String? ?? 'medium',
        command: json['command'] as String?,
      );
}

class DshManifest {
  const DshManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.runtime,
    this.permissions = const {},
    this.tools = const [],
  });

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;

  /// 'shell' (declarative command tools) or 'dart' (embedded plugin code).
  final String runtime;
  final Set<String> permissions;
  final List<DshToolDecl> tools;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'author': author,
        'runtime': runtime,
        'permissions': permissions.toList()..sort(),
        'tools': [for (final tool in tools) tool.toJson()],
      };

  static DshManifest fromJson(Map<String, dynamic> json) => DshManifest(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '',
        description: json['description'] as String? ?? '',
        author: json['author'] as String? ?? '',
        runtime: json['runtime'] as String? ?? 'shell',
        permissions: {
          for (final p in json['permissions'] as List? ?? const []) p as String,
        },
        tools: [
          for (final tool in json['tools'] as List? ?? const [])
            DshToolDecl.fromJson(tool as Map<String, dynamic>),
        ],
      );

  /// Parses a manifest from JSON text, throwing [DshManifestException] on
  /// invalid JSON or failed validation.
  static DshManifest parse(String jsonText) {
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      throw const DshManifestException('manifest is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const DshManifestException('manifest must be a JSON object');
    }
    final manifest = DshManifest.fromJson(decoded);
    final problems = validate(manifest);
    if (problems.isNotEmpty) {
      throw DshManifestException(problems.join('; '));
    }
    return manifest;
  }
}

/// Validation rules for a manifest. Returns human-readable problems.
List<String> validate(DshManifest manifest) {
  final problems = <String>[];
  if (!RegExp(r'^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$').hasMatch(manifest.id)) {
    problems.add('id must be reverse-DNS like dev.acme.tools');
  }
  if (manifest.name.trim().isEmpty) problems.add('name is required');
  if (!RegExp(r'^\d+\.\d+\.\d+($|[+-])').hasMatch(manifest.version)) {
    problems.add('version must be semver (x.y.z)');
  }
  if (manifest.runtime != 'shell' && manifest.runtime != 'dart') {
    problems.add("runtime must be 'shell' or 'dart'");
  }
  for (final permission in manifest.permissions) {
    if (!DshPermissions.all.contains(permission)) {
      problems.add('unknown permission: $permission');
    }
  }
  if (manifest.tools.isEmpty) problems.add('at least one tool is required');
  final names = <String>{};
  for (final tool in manifest.tools) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(tool.name)) {
      problems.add('tool name must be snake_case: ${tool.name}');
    }
    if (!names.add(tool.name)) {
      problems.add('duplicate tool name: ${tool.name}');
    }
    if (manifest.runtime == 'shell' && tool.command == null) {
      problems.add('shell tools need a command template: ${tool.name}');
    }
  }
  return problems;
}

class DshManifestException implements Exception {
  const DshManifestException(this.message);

  final String message;

  @override
  String toString() => 'DshManifestException: $message';
}
