import 'dart:convert';

import '../models.dart';
import '../runtime/tool_registry.dart';
import '../shell/shell_executor.dart';
import 'registry.dart';
import 'workspace.dart' show decodeArguments;

/// Structured terminal search tools for the agent (PHASE 43): `fast_find`
/// wraps fd (falling back to find) and `smart_grep` wraps rg (falling back
/// to grep). Both return JSON instead of raw text so the model can parse
/// results deterministically, enforce a head limit so one search cannot
/// blow the context, and never execute outside the process working
/// directory: subdirectories must be relative and may not contain `..`
/// segments or absolute prefixes.
///
/// The fd/rg probes run once per instance and are cached — missing tools
/// degrade to the classic engines instead of erroring, with
/// `fallbackUsed: true` so the model knows results came from the slower
/// path.
class TerminalSearchTools implements AgentToolRegistry {
  TerminalSearchTools({required this.runner, this.workingDirectory});

  final ProcessRunner runner;

  /// Passed through to every [ShellRequest]; null keeps the process default
  /// (the workspace root on Android hosts).
  final String? workingDirectory;

  bool? _hasFd;
  bool? _hasRg;

  static const terminalSpecs = <ToolSpec>[
    ToolSpec(
      'fast_find',
      '按文件名模式查找文件(fd,缺失时回退 find),返回结构化 JSON',
      'low',
    ),
    ToolSpec(
      'smart_grep',
      '按内容搜索文件(rg,缺失时回退 grep),返回结构化 JSON',
      'low',
    ),
  ];

  @override
  List<ToolSpec> get specs => terminalSpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        {
          'type': 'function',
          'function': {
            'name': 'fast_find',
            'description': terminalSpecs[0].description,
            'parameters': {
              'type': 'object',
              'properties': {
                'pattern': {'type': 'string', 'description': '文件名匹配模式(支持 glob 片段,如 *.dart)'},
                'subdir': {
                  'type': 'string',
                  'description': '可选,工作目录内的相对子目录;禁止绝对路径与 ..',
                },
              },
              'required': ['pattern'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'smart_grep',
            'description': terminalSpecs[1].description,
            'parameters': {
              'type': 'object',
              'properties': {
                'pattern': {'type': 'string', 'description': '要搜索的正则或文本'},
                'glob': {'type': 'string', 'description': '可选,文件名过滤,如 *.dart'},
                'subdir': {
                  'type': 'string',
                  'description': '可选,工作目录内的相对子目录;禁止绝对路径与 ..',
                },
                'context_lines': {
                  'type': 'number',
                  'description': '可选,每个命中附带的后文行数(0-5,默认 3)',
                },
                'max_results': {
                  'type': 'number',
                  'description': '可选,最多返回的命中数(默认 50,上限 100)',
                },
              },
              'required': ['pattern'],
            },
          },
        },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    switch (call.name) {
      case 'fast_find':
        return _fastFind(call);
      case 'smart_grep':
        return _smartGrep(call);
      default:
        throw ToolError('unknown tool: ${call.name}');
    }
  }

  Future<String> _fastFind(ToolCall call) async {
    final args = decodeArguments(call.argumentsJson);
    final pattern = args['pattern'];
    if (pattern is! String || pattern.trim().isEmpty) {
      return _errorJson('fast_find requires a non-empty "pattern"');
    }
    final subdir = _validatedSubdir(args['subdir']);
    if (subdir == null) {
      return _errorJson('subdir must be a relative path inside the working '
          'directory (no absolute prefix, no "..")');
    }
    if (!runner.isSupported) {
      return _errorJson('shell execution is not available on this host');
    }
    final hasFd = await _probeFd();
    final stopwatch = Stopwatch()..start();
    ShellResult result;
    final String engine;
    if (hasFd) {
      engine = 'fd';
      result = await _run(
        'fd --max-results 200 -- ${_shellQuote(pattern)}'
        '${subdir.isEmpty ? '' : ' ${_shellQuote(subdir)}'}',
        const Duration(seconds: 8),
      );
    } else {
      engine = 'find';
      result = await _run(
        "find ${subdir.isEmpty ? '.' : _shellQuote(subdir)} -name "
        "${_shellQuote('*$pattern*')} -type f",
        const Duration(seconds: 8),
      );
    }
    stopwatch.stop();
    if (_isHardFailure(result)) {
      return _errorJson('fast_find failed: ${result.formatted(maxCharsPerStream: 600)}');
    }
    final paths = result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    const cap = 100;
    final truncated = paths.length > cap;
    final entries = [
      for (final path in (truncated ? paths.sublist(0, cap) : paths))
        {'path': path, 'line': -1, 'text': '', 'after': <String>[]},
    ];
    return jsonEncode({
      'engine': engine,
      'fallbackUsed': engine == 'find',
      'entries': entries,
      'total': paths.length,
      'truncated': truncated,
      'elapsedMs': stopwatch.elapsedMilliseconds,
    });
  }

  Future<String> _smartGrep(ToolCall call) async {
    final args = decodeArguments(call.argumentsJson);
    final pattern = args['pattern'];
    if (pattern is! String || pattern.trim().isEmpty) {
      return _errorJson('smart_grep requires a non-empty "pattern"');
    }
    final subdir = _validatedSubdir(args['subdir']);
    if (subdir == null) {
      return _errorJson('subdir must be a relative path inside the working '
          'directory (no absolute prefix, no "..")');
    }
    final dynamic globArg = args['glob'];
    if (globArg != null && globArg is! String) {
      return _errorJson('"glob" must be a string');
    }
    final String glob = globArg as String? ?? '';
    final contextLines = _clampedInt(args['context_lines'], 0, 5, 3);
    final maxResults = _clampedInt(args['max_results'], 1, 100, 50);
    if (!runner.isSupported) {
      return _errorJson('shell execution is not available on this host');
    }
    final hasRg = await _probeRg();
    final stopwatch = Stopwatch()..start();
    ShellResult result;
    final String engine;
    final patternArg = _shellQuote(pattern);
    if (hasRg) {
      engine = 'rg';
      result = await _run(
        'rg -n --no-heading --max-count 400'
        '${glob.isEmpty ? '' : ' -g ${_shellQuote(glob)}'}'
        ' -A $contextLines -- $patternArg'
        '${subdir.isEmpty ? '' : ' ${_shellQuote(subdir)}'}',
        const Duration(seconds: 5),
      );
    } else {
      engine = 'grep';
      result = await _run(
        'grep -rn --binary-files=without-match'
        '${glob.isEmpty ? '' : " --include=${_shellQuote(glob)}"}'
        ' -A $contextLines -- $patternArg'
        '${subdir.isEmpty ? '' : ' ${_shellQuote(subdir)}'} .',
        const Duration(seconds: 5),
      );
    }
    stopwatch.stop();
    if (_isHardFailure(result)) {
      return _errorJson('smart_grep failed: ${result.formatted(maxCharsPerStream: 600)}');
    }
    final parsed = _parseGrepOutput(result.stdout, maxResults);
    return jsonEncode({
      'engine': engine,
      'fallbackUsed': engine == 'grep',
      'entries': parsed.entries,
      'total': parsed.total,
      'truncated': parsed.truncated,
      'elapsedMs': stopwatch.elapsedMilliseconds,
    });
  }

  /// `path:line:text` are hits; `path-line-text` (dash separator) are the
  /// trailing-context lines rg and GNU grep emit with -A; `--` separates
  /// match groups. Anything unparseable is ignored.
  _GrepParseResult _parseGrepOutput(String stdout, int maxResults) {
    final entries = <Map<String, dynamic>>[];
    var total = 0;
    for (final line in stdout.split('\n')) {
      if (line.isEmpty || line == '--') continue;
      final hit = _hitLine.firstMatch(line);
      if (hit != null) {
        total++;
        if (entries.length < maxResults) {
          entries.add({
            'path': hit.group(1)!,
            'line': int.tryParse(hit.group(2)!) ?? -1,
            'text': hit.group(3) ?? '',
            'after': <String>[],
          });
        }
        continue;
      }
      final context = _contextLine.firstMatch(line);
      if (context != null && entries.isNotEmpty && (entries.last['after'] as List<String>).length < 5) {
        (entries.last['after'] as List<String>).add(context.group(3) ?? '');
      }
    }
    return _GrepParseResult(entries, total, total > entries.length);
  }

  static final RegExp _hitLine = RegExp(r'^(.+?):(\d+):(.*)$');
  static final RegExp _contextLine = RegExp(r'^(.+?)-(\d+)-(.*)$');

  /// One-shot `command -v` probes with per-instance caching. Probe
  /// failures count as "missing" — the fallback chain then decides.
  Future<bool> _probeFd() async => _hasFd ??= await _probe('command -v fd');

  Future<bool> _probeRg() async => _hasRg ??= await _probe('command -v rg');

  Future<bool> _probe(String command) async {
    try {
      final result = await runner.run(
        ShellRequest(
          command: command,
          timeout: const Duration(seconds: 3),
          workingDirectory: workingDirectory,
        ),
      );
      return result.succeeded;
    } catch (_) {
      return false;
    }
  }

  Future<ShellResult> _run(String command, Duration timeout) {
    return runner.run(
      ShellRequest(
        command: command,
        timeout: timeout,
        workingDirectory: workingDirectory,
      ),
    );
  }

  bool _isHardFailure(ShellResult result) =>
      result.timedOut || result.cancelled || result.exitCode > 1;

  /// Returns the sanitized relative subdir ('' when absent), or null when
  /// the argument escapes the working directory.
  String? _validatedSubdir(dynamic value) {
    if (value == null) return '';
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('/') || trimmed.startsWith(r'\')) return null;
    if (trimmed.length >= 2 && trimmed[1] == ':') return null; // C:\...
    final segments = trimmed.split(RegExp(r'[\\/]'));
    if (segments.any((segment) => segment == '..')) return null;
    return trimmed;
  }

  int _clampedInt(dynamic value, int min, int max, int fallback) {
    if (value is! num) return fallback;
    return value.toInt().clamp(min, max);
  }

  String _errorJson(String message) =>
      jsonEncode({'error': message, 'entries': <dynamic>[], 'total': 0});

  /// Single-quote shell escaping: every `'` becomes `'\''`.
  String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";
}

class _GrepParseResult {
  const _GrepParseResult(this.entries, this.total, this.truncated);

  final List<Map<String, dynamic>> entries;
  final int total;
  final bool truncated;
}
