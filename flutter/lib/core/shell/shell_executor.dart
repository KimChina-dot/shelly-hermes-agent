import '../agent_core.dart';
import '../models.dart';
import '../runtime/tool_registry.dart';
import '../tools/registry.dart';
import '../tools/workspace.dart';

/// Severity of a shell command, graded by what it can destroy.
enum ShellRisk { low, medium, high, critical }

/// Host decision for a risk class.
enum ShellAction {
  /// Runs without user interaction (read-only commands).
  allow,

  /// AgentCore suspends for user approval before the executor runs.
  ask,

  /// Never runs; the model receives a policy denial it can react to.
  block,
}

/// Risk → action mapping. Defaults: read-only auto, anything mutating asks,
/// destructive patterns are blocked outright.
class ShellPolicy {
  const ShellPolicy({this.actions = const {}});

  final Map<ShellRisk, ShellAction> actions;

  ShellAction actionFor(ShellRisk risk) =>
      actions[risk] ?? _defaults[risk] ?? ShellAction.ask;

  static const _defaults = <ShellRisk, ShellAction>{
    ShellRisk.low: ShellAction.allow,
    ShellRisk.medium: ShellAction.ask,
    ShellRisk.high: ShellAction.ask,
    ShellRisk.critical: ShellAction.block,
  };

  static const ShellPolicy standard = ShellPolicy();
}

class ShellRequest {
  const ShellRequest({
    required this.command,
    this.timeout = const Duration(seconds: 120),
    this.workingDirectory,
  });

  final String command;
  final Duration timeout;
  final String? workingDirectory;
}

class ShellResult {
  const ShellResult({
    required this.exitCode,
    required this.duration,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.cancelled = false,
  });

  final int exitCode;
  final Duration duration;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool cancelled;

  bool get succeeded => exitCode == 0 && !timedOut && !cancelled;

  /// Truncates oversized output so one tool result cannot blow the context.
  String formatted({int maxCharsPerStream = 6000}) {
    String clip(String label, String text) {
      if (text.isEmpty) return '';
      final suffix = text.length > maxCharsPerStream
          ? '\n…(truncated ${text.length - maxCharsPerStream} chars)'
          : '';
      final body = text.length > maxCharsPerStream
          ? text.substring(0, maxCharsPerStream)
          : text;
      return '--- $label ---\n$body$suffix';
    }

    final header = timedOut
        ? 'timed out after ${duration.inSeconds}s'
        : cancelled
            ? 'cancelled'
            : 'exit=$exitCode (${duration.inMilliseconds}ms)';
    return [
      header,
      clip('stdout', stdout),
      clip('stderr', stderr),
    ].where((part) => part.isNotEmpty).join('\n');
  }
}

/// Platform port: spawns a shell process. Implemented with dart:io on VM/
/// Android hosts; the web dev harness reports [isSupported] == false.
abstract interface class ProcessRunner {
  bool get isSupported;

  Future<ShellResult> run(ShellRequest request,
      {CancellationSignal? cancellation});
}

/// Grades raw command strings. Order matters: critical beats high beats
/// low; anything unclassified defaults to medium (i.e. needs approval).
class ShellRiskClassifier {
  const ShellRiskClassifier();

  static final _critical = [
    RegExp(r'\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+|-[a-zA-Z]*r[a-zA-Z]*f)'),
    RegExp(r'\bsudo\b'),
    RegExp(r'\bmkfs\b'),
    RegExp(r'\bdd\s+if='),
    RegExp(r'>\s*/dev/[sh]d'),
    RegExp(r'\bchmod\s+777\b'),
    RegExp(r'\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba)?sh\b'),
    RegExp(r'\bdel\s+/[sq]'),
    RegExp(r'\brmdir\s+/s'),
    RegExp(r'\bformat\s+\w:'),
    RegExp(r'\bshutdown\b'),
    RegExp(r'\breboot\b'),
    RegExp(r':\(\)\{.*\};:'),
  ];

  static final _high = [
    RegExp(r'\brm\b'),
    RegExp(r'\bgit\s+push\b'),
    RegExp(r'\bgit\s+reset\s+--hard\b'),
    RegExp(r'\bgit\s+checkout\s+--\s'),
    RegExp(r'\bgit\s+clean\b'),
    RegExp(r'\bgit\s+branch\s+-D\b'),
    RegExp(r'\bnpm\s+publish\b'),
    RegExp(r'\bdocker\s+(rm|rmi)\b'),
    RegExp(r'\b(del|erase)\b'),
    RegExp(r'\bmv\s+.*\s+/dev/'),
  ];

  static final _low = [
    RegExp(r'^(ls|dir|pwd|cat|type|head|tail|wc|echo|which|where)\b'),
    RegExp(r'^grep\b'),
    RegExp(r'^findstr\b'),
    RegExp(r'^(flutter\s+(analyze|doctor|devices)|dart\s+(analyze|format)\b)'),
    RegExp(r'^git\s+(status|diff|log|branch|show|remote)\b'),
  ];

  ShellRisk classify(String command) {
    final cmd = command.trim();
    for (final pattern in _critical) {
      if (pattern.hasMatch(cmd)) return ShellRisk.critical;
    }
    for (final pattern in _high) {
      if (pattern.hasMatch(cmd)) return ShellRisk.high;
    }
    for (final pattern in _low) {
      if (pattern.hasMatch(cmd)) return ShellRisk.low;
    }
    return ShellRisk.medium;
  }
}

/// Orchestrates classification → policy → execution. Execution itself is
/// delegated to a [ProcessRunner]; when none is supported the tool reports
/// unavailability instead of throwing raw platform errors at the model.
class ShellExecutor {
  ShellExecutor({
    required this.runner,
    this.policy = ShellPolicy.standard,
    this.classifier = const ShellRiskClassifier(),
  });

  final ProcessRunner runner;
  final ShellPolicy policy;
  final ShellRiskClassifier classifier;

  ShellRisk classify(String command) => classifier.classify(command);

  Future<ShellResult> execute(
    String command, {
    Duration timeout = const Duration(seconds: 120),
    String? workingDirectory,
    CancellationSignal? cancellation,
  }) {
    return runner.run(
      ShellRequest(
        command: command,
        timeout: timeout,
        workingDirectory: workingDirectory,
      ),
      cancellation: cancellation,
    );
  }
}

/// `run_command` as an agent tool. Risk grading drives two gates:
/// [ShellPolicy] blocks outright, and the approval policy (see
/// [ShellApprovalPolicy]) asks the user for everything non-trivial.
class ShellToolRegistry implements AgentToolRegistry {
  ShellToolRegistry({
    required this.executor,
    this.policy = ShellPolicy.standard,
  });

  final ShellExecutor executor;
  final ShellPolicy policy;

  static const shellSpecs = <ToolSpec>[
    ToolSpec(
      'run_command',
      '在工作区执行 shell 命令,返回退出码、stdout 与 stderr',
      'high',
    ),
  ];

  @override
  List<ToolSpec> get specs => shellSpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
        {
          'type': 'function',
          'function': {
            'name': 'run_command',
            'description': shellSpecs.single.description,
            'parameters': {
              'type': 'object',
              'properties': {
                'command': {'type': 'string', 'description': '要执行的 shell 命令'},
                'timeout_seconds': {
                  'type': 'number',
                  'description': '可选,超时秒数(1-600,默认 120)',
                },
                'working_directory': {
                  'type': 'string',
                  'description': '可选,进程工作目录',
                },
              },
              'required': ['command'],
            },
          },
        },
      ];

  @override
  Future<String> execute(ToolCall call) async {
    if (call.name != 'run_command') {
      throw ToolError('unknown tool: ${call.name}');
    }
    final args = decodeArguments(call.argumentsJson);
    final command = args['command'];
    if (command is! String || command.trim().isEmpty) {
      throw const ToolArgumentsException('missing or empty "command"');
    }
    final risk = executor.classify(command);
    if (policy.actionFor(risk) == ShellAction.block) {
      return 'Error: command blocked by policy (risk: ${risk.name})';
    }
    if (!executor.runner.isSupported) {
      return 'Error: shell execution is not available on this host';
    }
    final timeoutSeconds = args['timeout_seconds'];
    final timeout = timeoutSeconds is num && timeoutSeconds > 0
        ? Duration(seconds: timeoutSeconds.clamp(1, 600).toInt())
        : const Duration(seconds: 120);
    final workingDirectory = args['working_directory'];
    final result = await executor.execute(
      command,
      timeout: timeout,
      workingDirectory: workingDirectory is String ? workingDirectory : null,
    );
    return 'risk=${risk.name}\n${result.formatted()}';
  }
}

/// Approval policy that lets low-risk shell commands run unattended while
/// deferring every other tool to the wrapped base policy.
class ShellApprovalPolicy implements ToolApprovalPolicy {
  const ShellApprovalPolicy({this.base = const _AlwaysAskPolicy()});

  final ToolApprovalPolicy base;

  @override
  bool requiresApproval(ToolCall call) {
    if (call.name != 'run_command') return base.requiresApproval(call);
    try {
      final args = decodeArguments(call.argumentsJson);
      final command = args['command'];
      if (command is! String) return true;
      // fail-open to approval: anything not provably low-risk must ask.
      return const ShellRiskClassifier().classify(command) !=
          ShellRisk.low;
    } catch (_) {
      // Fail closed: undecodable arguments must go through approval.
      return true;
    }
  }
}

class _AlwaysAskPolicy implements ToolApprovalPolicy {
  const _AlwaysAskPolicy();

  @override
  bool requiresApproval(ToolCall call) => true;
}
