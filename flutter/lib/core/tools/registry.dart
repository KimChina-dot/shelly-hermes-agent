import '../agent_core.dart';
import '../models.dart';
import '../runtime/tool_registry.dart';
import 'workspace.dart';

/// Trust level of a tool in the strategy engine.
enum ToolPolicyLevel {
  /// Executes without user interaction (read-only tools).
  allow,

  /// Suspends the agent until the user approves (mutating tools).
  confirm,

  /// Never executes; the model receives a policy denial instead.
  deny,
}

/// Per-tool trust policy. Defaults mirror the Kotlin host: read-only tools
/// auto-approve, everything else requires confirmation.
class ToolPolicy {
  const ToolPolicy({this.defaultLevel = ToolPolicyLevel.confirm, Map<String, ToolPolicyLevel>? levels})
      : levels = levels ?? const {};

  final ToolPolicyLevel defaultLevel;
  final Map<String, ToolPolicyLevel> levels;

  static const ToolPolicy standard = ToolPolicy(levels: {
    'read_file': ToolPolicyLevel.allow,
    'exists': ToolPolicyLevel.allow,
    'list_files': ToolPolicyLevel.allow,
    'search_files': ToolPolicyLevel.allow,
    'repo_map': ToolPolicyLevel.allow,
    'batch_read': ToolPolicyLevel.allow,
    'write_file': ToolPolicyLevel.confirm,
    'apply_patch': ToolPolicyLevel.confirm,
  });

  ToolPolicyLevel levelFor(String toolName) => levels[toolName] ?? defaultLevel;

  /// Adapter consumed by [AgentCore]: `confirm` tools need approval.
  ToolApprovalPolicy toApprovalPolicy() {
    return _PolicyAdapter(this);
  }
}

class _PolicyAdapter implements ToolApprovalPolicy {
  const _PolicyAdapter(this._policy);

  final ToolPolicy _policy;

  @override
  bool requiresApproval(ToolCall call) =>
      _policy.levelFor(call.name) == ToolPolicyLevel.confirm;
}

class ToolSpec {
  const ToolSpec(this.name, this.description, this.risk);

  final String name;
  final String description;
  final String risk;
}

/// Registry of built-in workspace tools. Implements the core [ToolExecutor]
/// interface so it plugs straight into [AgentCore]. Deny decisions short-
/// circuit execution: the model gets a denial string it can react to, and
/// the workspace stays untouched.
class WorkspaceToolRegistry implements AgentToolRegistry {
  WorkspaceToolRegistry({required this.workspace, this.policy = ToolPolicy.standard});

  final Workspace workspace;
  final ToolPolicy policy;

  static const workspaceSpecs = <ToolSpec>[
    ToolSpec('read_file', '读取工作区文件内容', 'low'),
    ToolSpec('exists', '检查文件是否存在', 'low'),
    ToolSpec('list_files', '列出工作区文件', 'low'),
    ToolSpec('search_files', '按名称或内容搜索文件', 'low'),
    ToolSpec('write_file', '写入或覆盖文件', 'medium'),
    ToolSpec('apply_patch', '按 hunk 应用代码补丁', 'high'),
  ];

  @override
  List<ToolSpec> get specs => workspaceSpecs;

  /// OpenAI function-calling definitions for these tools, so a real model
  /// can discover and call them. Parameter shapes mirror [execute].
  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        for (final spec in workspaceSpecs)
          {
            'type': 'function',
            'function': {
              'name': spec.name,
              'description': spec.description,
              'parameters': _parameterSchemas[spec.name] ??
                  {'type': 'object', 'properties': <String, dynamic>{}},
            },
          },
      ];

  static const _parameterSchemas = <String, Map<String, dynamic>>{
    'read_file': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '工作区内的相对路径'},
      },
      'required': ['path'],
    },
    'exists': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '工作区内的相对路径'},
      },
      'required': ['path'],
    },
    'list_files': {
      'type': 'object',
      'properties': {
        'prefix': {'type': 'string', 'description': '可选,按子串过滤文件路径'},
      },
    },
    'search_files': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '按名称或内容搜索的关键词'},
      },
      'required': ['query'],
    },
    'write_file': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '工作区内的相对路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    },
    'apply_patch': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '要修改的文件相对路径'},
        'patch': {'type': 'string', 'description': 'Shelly 风格补丁:@@ 段落,行首为空格/减号/加号'},
      },
      'required': ['path', 'patch'],
    },
  };

  @override
  Future<String> execute(ToolCall call) async {
    if (policy.levelFor(call.name) == ToolPolicyLevel.deny) {
      return 'Error: tool "${call.name}" denied by policy';
    }
    final args = decodeArguments(call.argumentsJson);
    switch (call.name) {
      case 'read_file':
        return _requireString(args, 'path', (path) async {
          final content = await workspace.readFile(path);
          if (content == null) throw ToolError('file not found: $path');
          return content;
        });
      case 'exists':
        return _requireString(args, 'path', (path) async {
          final found = await workspace.exists(path);
          return found ? 'true' : 'false';
        });
      case 'list_files':
        return _optionalString(args, 'prefix', (prefix) async {
          final files = await workspace.listFiles(prefix ?? '');
          return files.isEmpty ? '(empty)' : files.join('\n');
        });
      case 'search_files':
        return _requireString(args, 'query', (query) async {
          final files = await workspace.searchFiles(query);
          return files.isEmpty ? '(no matches)' : files.join('\n');
        });
      case 'write_file':
        return _requireString(args, 'path', (path) async {
          final content = args['content'];
          if (content is! String) {
            throw const ToolArgumentsException('write_file requires string "content"');
          }
          await workspace.writeFile(path, content);
          return 'written: $path (${content.length} bytes)';
        });
      case 'apply_patch':
        return _requireString(args, 'path', (path) async {
          final patch = args['patch'];
          if (patch is! String) {
            throw const ToolArgumentsException('apply_patch requires string "patch"');
          }
          final original = await workspace.readFile(path);
          if (original == null) {
            throw ToolError('file not found: $path');
          }
          final updated = applyPatchToContent(original, patch);
          await workspace.writeFile(path, updated);
          final hunks = parseHunks(patch).length;
          return 'patched: $path ($hunks hunk${hunks == 1 ? '' : 's'})';
        });
      default:
        throw ToolError('unknown tool: ${call.name}');
    }
  }

  Future<String> _requireString(
    Map<String, dynamic> args,
    String key,
    Future<String> Function(String value) action,
  ) async {
    final value = args[key];
    if (value is! String || value.isEmpty) {
      throw ToolArgumentsException('missing or empty "$key"');
    }
    return action(value);
  }

  Future<String> _optionalString(
    Map<String, dynamic> args,
    String key,
    Future<String> Function(String? value) action,
  ) async {
    final value = args[key];
    if (value != null && value is! String) {
      throw ToolArgumentsException('"$key" must be a string');
    }
    return action(value as String?);
  }
}

class ToolError implements Exception {
  const ToolError(this.message);

  final String message;

  @override
  String toString() => message;
}
