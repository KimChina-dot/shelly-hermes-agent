/// PHASE 46 — trajectory-level eval scenarios for the real AgentCore loop.
///
/// Each scenario is a deterministic regression case in the Anthropic evals
/// sense: it grades *what the agent produced* — the workspace outcome after
/// the run and the trajectory it took (tools used, order, rounds) — never
/// the exact textual path. Rubric checks are plain Dart predicates, so the
/// suite needs no LLM judge and is fully reproducible.
///
/// The harness in [runScenario] drives the real [AgentCore] with:
/// - a scripted [StreamingModelGateway] (replies queued up front),
/// - a [MemoryWorkspace] seeded by the scenario,
/// - the REAL [WorkspaceToolRegistry] and [ShellToolRegistry] (policy and
///   risk classification included),
/// - a shell [ProcessRunner] that refuses to execute (evals must never spawn
///   real processes; policy-blocked and unsupported paths still work).
library;

import 'dart:convert';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/memory/memory_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

// ---------------------------------------------------------------------------
// Scenario + rubric model
// ---------------------------------------------------------------------------

/// One deterministic rubric check. [name] is what the PASS/FAIL report shows.
class RubricCheck {
  const RubricCheck(this.name, this.predicate);

  final String name;
  final bool Function(EvalRunEvidence evidence) predicate;
}

/// Everything an outcome/trajectory check may consult after a run.
class EvalRunEvidence {
  EvalRunEvidence({
    required this.result,
    required this.runError,
    required this.workspace,
    required this.toolCallOrder,
    required this.toolResults,
    required this.failedToolCalls,
    required this.modelRounds,
    required this.systemPromptsSeen,
    required this.approvalRequests,
    required this.shellCommands,
    required this.checkpointsSaved,
  });

  /// Terminal [AgentResult]; null when the run threw out of [AgentCore].
  final AgentResult? result;

  /// Non-null when the harness itself failed (e.g. scripted replies ran out).
  final String? runError;

  /// Post-run workspace state (outcome grading).
  final MemoryWorkspace workspace;

  /// Tool names in execution order (trajectory grading).
  final List<String> toolCallOrder;

  /// Tool name → returned result strings, in call order.
  final Map<String, List<String>> toolResults;

  /// Tool calls whose execution threw (ToolFinished.succeeded == false).
  final List<String> failedToolCalls;

  /// Number of model rounds actually consumed.
  final int modelRounds;

  /// System-role message content the model saw at round start (memory /
  /// persona composition grading).
  final List<String> systemPromptsSeen;

  /// Tool names that were routed through the approval gateway.
  final List<String> approvalRequests;

  /// Commands that reached the shell runner (must stay empty in evals).
  final List<String> shellCommands;

  final int checkpointsSaved;

  /// Final assistant message when the run completed, else null.
  String? get finalAnswer =>
      result is AgentCompleted ? (result as AgentCompleted).message : null;
}

/// A single eval case: user task + scripted gateway replies + seeded
/// workspace + deterministic rubric.
class EvalScenario {
  const EvalScenario({
    required this.name,
    required this.description,
    required this.userTask,
    required this.script,
    required this.rubric,
    this.seedFiles = const {},
    this.limits = const AgentLimits(maxRounds: 10, maxToolCalls: 16),
    this.persona = '',
    this.memories = const [],
    this.systemPrompt,
    this.composeMemoryPrompt = false,
  });

  final String name;
  final String description;
  final String userTask;

  /// Scripted model replies: tool-call rounds first, final answer last.
  final List<ModelReply> script;

  /// Files present in the workspace before the run.
  final Map<String, String> seedFiles;

  /// Deterministic checks graded against [EvalRunEvidence].
  final List<RubricCheck> rubric;

  final AgentLimits limits;

  /// Persona used only with [composeMemoryPrompt].
  final String persona;

  /// Long-term memories used only with [composeMemoryPrompt].
  final List<MemoryFact> memories;

  /// Verbatim system prompt prepended before the user message.
  final String? systemPrompt;

  /// When true the harness composes the system prompt exactly like
  /// chat_session.dart does: systemPromptWithMemory(persona:
  /// personaWithToolRules(persona), memories: memories). The composition
  /// call itself lives in trajectory_test.dart (visibleForTesting seam).
  final bool composeMemoryPrompt;
}

/// Aggregated verdict for one scenario, rendered by the harness report.
class ScenarioOutcome {
  const ScenarioOutcome({
    required this.name,
    required this.passed,
    required this.failedChecks,
    required this.modelRounds,
    required this.toolCallCount,
    this.runError,
  });

  final String name;
  final bool passed;
  final List<String> failedChecks;
  final int modelRounds;
  final int toolCallCount;
  final String? runError;
}

// ---------------------------------------------------------------------------
// Rubric check builders
// ---------------------------------------------------------------------------

/// Outcome: the run finished with [AgentCompleted].
RubricCheck completed() => RubricCheck(
      'trajectory: run completed (AgentCompleted)',
      (e) => e.result is AgentCompleted,
    );

/// Outcome: the final assistant message contains [needle].
RubricCheck finalAnswerContains(String needle) => RubricCheck(
      'outcome: final answer contains "$needle"',
      (e) => (e.finalAnswer ?? '').contains(needle),
    );

/// Outcome: file content equals [expected] exactly after the run.
RubricCheck fileEquals(String path, String expected) => RubricCheck(
      'outcome: $path equals expected content',
      (e) => e.workspace.files[path] == expected,
    );

/// Outcome: file exists after the run.
RubricCheck filePresent(String path) => RubricCheck(
      'outcome: $path exists',
      (e) => e.workspace.files.containsKey(path),
    );

/// Outcome: file does not exist after the run.
RubricCheck fileAbsent(String path) => RubricCheck(
      'outcome: $path absent',
      (e) => !e.workspace.files.containsKey(path),
    );

/// Outcome: workspace file map is byte-identical to the seed (nothing was
/// mutated, nothing was added or removed).
RubricCheck workspaceUnchanged(Map<String, String> seed) =>
    RubricCheck('outcome: workspace unchanged after run', (e) {
      final files = e.workspace.files;
      if (files.length != seed.length) return false;
      for (final entry in seed.entries) {
        if (files[entry.key] != entry.value) return false;
      }
      return true;
    });

/// Trajectory: the exact tool sequence executed, in order.
RubricCheck toolSequence(List<String> expected) => RubricCheck(
      'trajectory: tool order == ${expected.join(' -> ')}',
      (e) => _listEquals(e.toolCallOrder, expected),
    );

/// Trajectory: the named tool was used at least once.
RubricCheck usedTool(String name) => RubricCheck(
      'trajectory: used tool $name',
      (e) => e.toolCallOrder.contains(name),
    );

/// Trajectory: none of the named tools were ever called.
RubricCheck noToolNamed(List<String> names) => RubricCheck(
      'trajectory: never uses ${names.join(', ')}',
      (e) => !e.toolCallOrder.any((used) => names.contains(used)),
    );

/// Trajectory: at most [n] model rounds consumed.
RubricCheck modelRoundsAtMost(int n) => RubricCheck(
      'trajectory: <= $n model rounds (actual ${'{rounds}'})',
      (e) => e.modelRounds <= n,
    );

/// Trajectory: at most [n] tool calls executed.
RubricCheck toolCallsAtMost(int n) => RubricCheck(
      'trajectory: <= $n tool calls',
      (e) => e.toolCallOrder.length <= n,
    );

/// Trajectory: no tool execution threw an exception.
RubricCheck noToolFailures() => RubricCheck(
      'trajectory: no tool execution exceptions',
      (e) => e.failedToolCalls.isEmpty,
    );

/// Trajectory: some call of [tool] returned a result containing [needle].
RubricCheck toolResultContains(String tool, String needle) => RubricCheck(
      'trajectory: $tool result contains "$needle"',
      (e) => (e.toolResults[tool] ?? const []).any((r) => r.contains(needle)),
    );

/// Trajectory: the named tool went through the approval gateway.
RubricCheck approvalAskedFor(String tool) => RubricCheck(
      'trajectory: $tool went through approval',
      (e) => e.approvalRequests.contains(tool),
    );

/// Outcome: the shell runner never actually spawned a command.
RubricCheck shellNeverExecuted() => RubricCheck(
      'outcome: no shell command actually executed',
      (e) => e.shellCommands.isEmpty,
    );

/// Trajectory: the system prompt the model saw contains [needle].
RubricCheck systemPromptContains(String needle) => RubricCheck(
      'trajectory: system prompt contains "$needle"',
      (e) =>
          e.systemPromptsSeen.isNotEmpty &&
          e.systemPromptsSeen.first.contains(needle),
    );

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Scripted model gateway: replays queued replies, then fails loudly so a
/// runaway loop surfaces as a harness error instead of hanging.
class ScriptedGateway implements StreamingModelGateway {
  ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  var _cursor = 0;

  /// What the model saw each round, for system-prompt / tool-result checks.
  final List<List<AgentMessage>> requests = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    requests.add(List.of(messages));
    if (_cursor >= replies.length) {
      throw StateError(
        'scripted replies exhausted after ${requests.length} rounds',
      );
    }
    return replies[_cursor++];
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

/// Approval gateway that records requests and approves everything, matching
/// the "auto-accept" operator mode evals simulate. Mutating tools still walk
/// the approval path, which the rubric can assert on.
class _ApproveAllGateway implements ApprovalGateway {
  final List<String> requestedTools = [];

  @override
  Future<ApprovalDecision> request(ToolCall call) async {
    requestedTools.add(call.name);
    return ApprovalDecision.approve;
  }
}

class _MemoryCheckpoints implements CheckpointStore {
  final List<AgentCheckpoint> saved = [];

  @override
  Future<void> save(AgentCheckpoint checkpoint) async => saved.add(checkpoint);
}

class _EvalObserver implements AgentObserver {
  final List<String> toolCallOrder = [];
  final Map<String, List<String>> toolResults = {};
  final List<String> failedToolCalls = [];

  @override
  void onEvent(AgentEvent event) {
    if (event is ToolStarted) toolCallOrder.add(event.toolName);
    if (event is ToolFinished) {
      toolResults.putIfAbsent(event.toolName, () => []).add(event.result ?? '');
      if (!event.succeeded) failedToolCalls.add(event.toolName);
    }
  }
}

/// Shell runner that refuses to execute anything: evals must be hermetic.
/// The unsupported flag keeps `run_command` on the operator-safe error
/// string path ("shell not available"); blocked commands never reach here.
class _NeverExecuteRunner implements ProcessRunner {
  final List<String> commands = [];

  @override
  bool get isSupported => false;

  @override
  Future<ShellResult> run(
    ShellRequest request, {
    CancellationSignal? cancellation,
  }) async {
    commands.add(request.command);
    throw StateError('eval harness must never execute real shell commands');
  }
}

/// Runs one scenario end-to-end against the real [AgentCore] and grades its
/// rubric. Never throws for scenario failures; failures are reported via
/// [ScenarioOutcome].
Future<ScenarioOutcome> runScenario(
  EvalScenario scenario, {
  String? systemPrompt,
}) async {
  final workspace = MemoryWorkspace(
    scenario.seedFiles.isEmpty ? null : Map.of(scenario.seedFiles),
  );
  final gateway = ScriptedGateway(scenario.script);
  final shellRunner = _NeverExecuteRunner();
  final registry = CompositeToolRegistry([
    WorkspaceToolRegistry(workspace: workspace),
    ShellToolRegistry(executor: ShellExecutor(runner: shellRunner)),
  ]);
  final approvals = _ApproveAllGateway();
  final checkpoints = _MemoryCheckpoints();
  final observer = _EvalObserver();
  final core = AgentCore(
    model: gateway,
    tools: registry,
    approvals: approvals,
    checkpoints: checkpoints,
    limits: scenario.limits,
    approvalPolicy: ShellApprovalPolicy(
      base: ToolPolicy.standard.toApprovalPolicy(),
    ),
    observer: observer,
  );
  final messages = <AgentMessage>[
    if (systemPrompt != null && systemPrompt.isNotEmpty)
      AgentMessage(role: MessageRole.system, content: systemPrompt),
    AgentMessage(role: MessageRole.user, content: scenario.userTask),
  ];

  AgentResult? result;
  String? runError;
  try {
    result = await core.run(messages, CancelFlag());
  } catch (error) {
    runError = error.toString();
  }

  final evidence = EvalRunEvidence(
    result: result,
    runError: runError,
    workspace: workspace,
    toolCallOrder: observer.toolCallOrder,
    toolResults: observer.toolResults,
    failedToolCalls: observer.failedToolCalls,
    modelRounds: gateway.requests.length,
    systemPromptsSeen: [
      for (final request in gateway.requests)
        if (request.isNotEmpty && request.first.role == MessageRole.system)
          request.first.content,
    ],
    approvalRequests: approvals.requestedTools,
    shellCommands: shellRunner.commands,
    checkpointsSaved: checkpoints.saved.length,
  );

  final failed = <String>[];
  for (final check in scenario.rubric) {
    var ok = false;
    try {
      ok = check.predicate(evidence);
    } catch (_) {
      ok = false;
    }
    if (!ok) failed.add(check.name);
  }
  return ScenarioOutcome(
    name: scenario.name,
    passed: failed.isEmpty,
    failedChecks: failed,
    modelRounds: evidence.modelRounds,
    toolCallCount: evidence.toolCallOrder.length,
    runError: runError,
  );
}

// ---------------------------------------------------------------------------
// Fixed seed fixtures
// ---------------------------------------------------------------------------

const String architectureDoc = '# 架构\n'
    '应用分为三层:UI 层、AgentCore 引擎层与工具层。\n'
    'AgentCore 负责在模型轮次之间调度工具调用。';

const String todoContent = '# TODO\n- 跑通评估基线\n';

const String configBefore = 'name: demo\nversion: 1.0.0';
const String configAfter = 'name: demo\nversion: 1.1.0';
const String versionPatch = '@@\n-version: 1.0.0\n+version: 1.1.0';

const String counterCreated = 'int count = 0;';
const String counterAfter = 'int count = 1;';
const String counterPatch = '@@\n-int count = 0;\n+int count = 1;';

const String loginServiceSource = 'class LoginService {\n'
    '  bool submit(String user, String pass) =>\n'
    '      user.isNotEmpty && pass.isNotEmpty;\n'
    '}\n';

const String mainDotDartSource = 'void main() {\n  print("demo");\n}\n';

Map<String, String> get searchSeedFiles => const {
      'src/auth/login.dart': loginServiceSource,
      'src/auth/logout.dart': 'class LogoutService {}',
      'README.md': '# Demo app\n参考 docs 目录。',
    };

Map<String, String> get assetsSeedFiles => const {
      'assets/banner.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
      'assets/logo.svg': '<svg xmlns="http://www.w3.org/2000/svg"/>',
      'lib/main.dart': mainDotDartSource,
    };

Map<String, String> get blockedCommandSeedFiles => const {
      'lib/main.dart': mainDotDartSource,
      'build/cache.txt': 'stale build cache',
    };

// ---------------------------------------------------------------------------
// The ten scenarios
// ---------------------------------------------------------------------------

/// The deterministic regression baseline: all ten must always pass.
List<EvalScenario> evalScenarios() => [
      // (1) read + summarize -------------------------------------------------
      EvalScenario(
        name: '01-read-and-summarize',
        description: 'Reads a seeded doc and answers from its content; '
            'nothing is mutated.',
        userTask: '总结 docs/architecture.md 的要点',
        seedFiles: {'docs/architecture.md': architectureDoc},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's01-t1',
              name: 'read_file',
              argumentsJson: '{"path":"docs/architecture.md"}',
            ),
          ]),
          ModelReply(
            content: '文档描述了三层架构:UI 层、AgentCore 引擎层与工具层,'
                '引擎负责在轮次之间调度工具调用。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['read_file']),
          finalAnswerContains('三层'),
          fileEquals('docs/architecture.md', architectureDoc),
          toolCallsAtMost(1),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (2) write a new file -------------------------------------------------
      EvalScenario(
        name: '02-write-new-file',
        description: 'Creates a new markdown file via write_file; the '
            'mutating call must go through approval.',
        userTask: '把待办事项写进 notes/todo.md',
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's02-t1',
              name: 'write_file',
              argumentsJson: jsonEncode({
                'path': 'notes/todo.md',
                'content': todoContent,
              }),
            ),
          ]),
          const ModelReply(content: '已创建 notes/todo.md,TODO 列表写好了。'),
        ],
        rubric: [
          completed(),
          usedTool('write_file'),
          approvalAskedFor('write_file'),
          fileEquals('notes/todo.md', todoContent),
          filePresent('notes/todo.md'),
          finalAnswerContains('todo.md'),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (3) apply_patch to an existing file ----------------------------------
      EvalScenario(
        name: '03-apply-patch-existing',
        description: 'Patches a version line in an existing file with a '
            'single @@ hunk.',
        userTask: '把 lib/config.dart 的版本号升到 1.1.0',
        seedFiles: {'lib/config.dart': configBefore},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's03-t1',
              name: 'apply_patch',
              argumentsJson: jsonEncode({
                'path': 'lib/config.dart',
                'patch': versionPatch,
              }),
            ),
          ]),
          const ModelReply(content: '已把 version 升级到 1.1.0。'),
        ],
        rubric: [
          completed(),
          usedTool('apply_patch'),
          approvalAskedFor('apply_patch'),
          fileEquals('lib/config.dart', configAfter),
          fileAbsent('lib/config.dart.orig'),
          finalAnswerContains('1.1.0'),
          modelRoundsAtMost(2),
          noToolFailures(),
        ],
      ),

      // (4) search_files then read_file --------------------------------------
      EvalScenario(
        name: '04-search-then-read',
        description: 'Locates the login implementation by search, then reads '
            'the exact file before answering.',
        userTask: '找到登录逻辑在哪个文件并说明提交前做了什么校验',
        seedFiles: searchSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's04-t1',
              name: 'search_files',
              argumentsJson: '{"query":"login"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's04-t2',
              name: 'read_file',
              argumentsJson: '{"path":"src/auth/login.dart"}',
            ),
          ]),
          ModelReply(
            content: '登录逻辑在 src/auth/login.dart 的 LoginService 中,'
                '提交前校验用户名和密码非空。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['search_files', 'read_file']),
          toolResultContains('search_files', 'src/auth/login.dart'),
          fileEquals('src/auth/login.dart', loginServiceSource),
          finalAnswerContains('LoginService'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (5) multi-step create-then-edit --------------------------------------
      EvalScenario(
        name: '05-create-then-edit',
        description: 'Two mutating steps in one task: create a file, then '
            'patch it; order is graded.',
        userTask: '新建 src/counter.dart 并把计数初始值改成 1',
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's05-t1',
              name: 'write_file',
              argumentsJson: jsonEncode({
                'path': 'src/counter.dart',
                'content': counterCreated,
              }),
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's05-t2',
              name: 'apply_patch',
              argumentsJson: jsonEncode({
                'path': 'src/counter.dart',
                'patch': counterPatch,
              }),
            ),
          ]),
          const ModelReply(content: '已创建 src/counter.dart 并把初始值改为 1。'),
        ],
        rubric: [
          completed(),
          toolSequence(['write_file', 'apply_patch']),
          approvalAskedFor('write_file'),
          approvalAskedFor('apply_patch'),
          fileEquals('src/counter.dart', counterAfter),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (6) tool error recovery ----------------------------------------------
      EvalScenario(
        name: '06-tool-error-recovery',
        description: 'First call fails: run_command hits an unsupported shell '
            'host and receives an operator-safe error string; the agent '
            'recovers by switching to the workspace read_file tool. (Raw '
            'ToolError aborts the round by design in AgentCore, so recovery '
            'is graded on the error-string path real registries emit.)',
        userTask: '检查 lib/main.dart 有没有问题',
        seedFiles: {'lib/main.dart': mainDotDartSource},
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's06-t1',
              name: 'run_command',
              argumentsJson: '{"command":"flutter analyze"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's06-t2',
              name: 'read_file',
              argumentsJson: '{"path":"lib/main.dart"}',
            ),
          ]),
          ModelReply(
            content: '宿主不支持 shell,我改用工作区工具直接读取了 lib/main.dart,'
                '内容正常。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['run_command', 'read_file']),
          toolResultContains('run_command', 'Error:'),
          usedTool('read_file'),
          fileEquals('lib/main.dart', mainDotDartSource),
          finalAnswerContains('lib/main.dart'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),

      // (7) policy-blocked destructive command -------------------------------
      EvalScenario(
        name: '07-block-destructive-command',
        description: 'The model attempts rm -rf; ShellPolicy grades it '
            'critical and blocks it. Outcome: workspace intact, no process '
            'ever spawned.',
        userTask: '清理 build 目录',
        seedFiles: blockedCommandSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's07-t1',
              name: 'run_command',
              argumentsJson: '{"command":"rm -rf build/"}',
            ),
          ]),
          ModelReply(
            content: '删除命令被策略拦截(risk: critical),工作区没有改动。',
          ),
        ],
        rubric: [
          completed(),
          usedTool('run_command'),
          toolResultContains('run_command', 'blocked by policy'),
          approvalAskedFor('run_command'),
          shellNeverExecuted(),
          workspaceUnchanged(blockedCommandSeedFiles),
          filePresent('build/cache.txt'),
          finalAnswerContains('拦截'),
          noToolFailures(),
        ],
      ),

      // (8) memory-injected answer -------------------------------------------
      EvalScenario(
        name: '08-memory-injected-answer',
        description: 'Persona + long-term memory composed into the system '
            'prompt via the same helper chat_session.dart uses; the answer '
            'uses the stored fact. Tool rules must ride along.',
        userTask: '我平时喜欢什么样的界面主题?',
        persona: '你是 Shelly,一名严谨的结对编程助手。',
        memories: [
          MemoryFact(
            id: 'fact-dark-mode',
            text: '用户偏好深色主题的界面',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        composeMemoryPrompt: true,
        script: [
          const ModelReply(
            content: '根据长期记忆,你偏好深色主题,我会默认沿用深色界面。',
          ),
        ],
        rubric: [
          completed(),
          systemPromptContains('Shelly'),
          systemPromptContains('工具使用守则'),
          systemPromptContains('长期记忆'),
          systemPromptContains('用户偏好深色主题'),
          finalAnswerContains('深色主题'),
          toolCallsAtMost(0),
          modelRoundsAtMost(1),
        ],
      ),

      // (9) no-tool direct answer --------------------------------------------
      EvalScenario(
        name: '09-no-tool-direct-answer',
        description: 'A pure knowledge question: the agent must answer in one '
            'round without touching any tool.',
        userTask: '用一句话解释什么是回归测试',
        script: [
          ModelReply(
            content: '回归测试是在改动之后重新运行已有用例,'
                '确认旧功能没有被新改动破坏。',
          ),
        ],
        rubric: [
          completed(),
          toolCallsAtMost(0),
          modelRoundsAtMost(1),
          finalAnswerContains('回归测试'),
          noToolFailures(),
        ],
      ),

      // (10) list_files then exists -------------------------------------------
      EvalScenario(
        name: '10-list-files-then-exists',
        description: 'Inventory then verify: list the assets prefix, confirm '
            'one asset exists, answer from tool results.',
        userTask: 'assets 目录下有什么?logo.svg 存在吗?',
        seedFiles: assetsSeedFiles,
        script: [
          ModelReply(toolCalls: [
            ToolCall(
              id: 's10-t1',
              name: 'list_files',
              argumentsJson: '{"prefix":"assets"}',
            ),
          ]),
          ModelReply(toolCalls: [
            ToolCall(
              id: 's10-t2',
              name: 'exists',
              argumentsJson: '{"path":"assets/logo.svg"}',
            ),
          ]),
          ModelReply(
            content: 'assets 目录下有 banner.svg 和 logo.svg,logo.svg 存在。',
          ),
        ],
        rubric: [
          completed(),
          toolSequence(['list_files', 'exists']),
          toolResultContains('list_files', 'assets/logo.svg'),
          toolResultContains('exists', 'true'),
          filePresent('assets/logo.svg'),
          finalAnswerContains('logo.svg'),
          modelRoundsAtMost(3),
          noToolFailures(),
        ],
      ),
    ];

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
