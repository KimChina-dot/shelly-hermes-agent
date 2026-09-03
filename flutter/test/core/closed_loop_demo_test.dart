/// PHASE 17 — 三系统完整闭环 Demo:一个「Flutter 登录修复」场景串起
/// Shelly(检测/Shell/Git/沙箱)、Hermes(账本/回注/Reflection/Forgetting)
/// 与 DSH(插件安装/信任策略/受控执行)。全部走真实 AgentRuntime + AgentCore,
/// 只有模型与进程用脚本假体。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/approval_broker.dart';
import 'package:shelly_hermes/core/dsh/plugin.dart';
import 'package:shelly_hermes/core/workspace/project.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/dsh/hermes_bridge.dart';
import 'package:shelly_hermes/core/dsh/installer.dart';
import 'package:shelly_hermes/core/dsh/registry.dart';
import 'package:shelly_hermes/core/dsh/tool_registry.dart';
import 'package:shelly_hermes/core/git/git_manager.dart';
import 'package:shelly_hermes/core/git/git_sandbox.dart';
import 'package:shelly_hermes/core/hermes/forgetting.dart';
import 'package:shelly_hermes/core/hermes/hermes_memory.dart';
import 'package:shelly_hermes/core/hermes/knowledge.dart';
import 'package:shelly_hermes/core/hermes/knowledge_store.dart';
import 'package:shelly_hermes/core/hermes/knowledge_tool.dart';
import 'package:shelly_hermes/core/hermes/reflection.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/runtime/agent_context.dart';
import 'package:shelly_hermes/core/runtime/agent_runtime.dart';
import 'package:shelly_hermes/core/runtime/tool_registry.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/registry.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/core/workspace/workspace_manager.dart';

class _ScriptedModel implements StreamingModelGateway {
  _ScriptedModel(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seen = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seen.add(List.of(messages));
    return replies.removeAt(0);
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) =>
      complete(messages);
}

class _ApproveAll implements ApprovalGateway {
  final List<ToolCall> asked = [];

  @override
  Future<ApprovalDecision> request(ToolCall call) async {
    asked.add(call);
    return ApprovalDecision.approve;
  }
}

class _SavingCheckpoints implements CheckpointStore {
  final List<AgentCheckpoint> saved = [];

  @override
  Future<void> save(AgentCheckpoint checkpoint) async => saved.add(checkpoint);
}

class _EventLog implements AgentObserver {
  final List<String> started = [];
  final Map<String, String> results = {};

  @override
  void onEvent(AgentEvent event) {
    if (event is ToolStarted) started.add(event.toolName);
    if (event is ToolFinished && event.result != null) {
      results[event.toolName] = event.result!;
    }
  }
}

class _RecordingRunner implements ProcessRunner {
  final List<String> commands = [];

  @override
  bool get isSupported => true;

  @override
  Future<ShellResult> run(ShellRequest request,
      {CancellationSignal? cancellation}) async {
    commands.add(request.command);
    return ShellResult(
      exitCode: 0,
      duration: const Duration(milliseconds: 5),
      stdout: 'No issues found!',
    );
  }
}

class _GitFakeRunner implements ProcessRunner {
  @override
  bool get isSupported => true;

  @override
  Future<ShellResult> run(ShellRequest request,
      {CancellationSignal? cancellation}) async {
    final c = request.command;
    if (c.contains('rev-parse')) {
      return const ShellResult(
          exitCode: 0, duration: Duration(milliseconds: 1), stdout: 'true\n');
    }
    if (c.startsWith('git status')) {
      return const ShellResult(
        exitCode: 0,
        duration: Duration(milliseconds: 1),
        stdout: '## main\n M lib/login.dart\n?? lib/extra.dart\n',
      );
    }
    return ShellResult(
        exitCode: 1, duration: const Duration(milliseconds: 1), stderr: c);
  }
}

const _manifestText = '''
{
  "id": "dev.acme.buildcheck",
  "name": "Acme Build Checker",
  "version": "1.0.0",
  "description": "Runs the vendor build gate before a fix is called done",
  "author": "Acme",
  "runtime": "shell",
  "permissions": ["terminal.execute"],
  "tools": [
    {
      "name": "vendor_build",
      "description": "Run the vendor build gate",
      "risk": "medium",
      "command": "flutter build apk --debug --target={target}"
    }
  ]
}
''';

void main() {
  test('三系统闭环:Flutter 登录修复 12 步', () async {
    final ws = MemoryWorkspace();

    // ---- [1] Shelly:项目检测(Flutter > Android > Git > plain) ----
    await ws.writeFile(
        'pubspec.yaml', 'name: login_app\ndependencies:\n  flutter:\n    sdk: flutter\n');
    await ws.writeFile('lib/login.dart', 'void submit() { /* TODO 修复登录 */ }');
    await ws.writeFile('.gitignore', '.dart_tool/\n');
    final project = await WorkspaceManager(workspace: ws).detectProject();
    expect(project.kind, ProjectKind.flutter);
    expect(project.name, 'login_app');
    expect(project.isGitRepo, isTrue);

    final shellRunner = _RecordingRunner();
    final shellExecutor = ShellExecutor(runner: shellRunner);
    final store = HermesKnowledgeStore(workspace: ws, project: project.name);

    // ---- [2] Hermes:首日账本为空 → 首轮运行不应注入任何记忆 ----
    expect(await store.loadAll(), isEmpty);
    final approvals = _ApproveAll();
    final checkpoints = _SavingCheckpoints();
    final events = _EventLog();
    final model1 = _ScriptedModel([
      const ModelReply(
          toolCalls: [
            ToolCall(id: 'c1', name: 'read_file', argumentsJson: '{"path":"lib/login.dart"}')
          ]),
      const ModelReply(
          toolCalls: [
            ToolCall(id: 'c2', name: 'run_command', argumentsJson: '{"command":"flutter analyze"}')
          ]),
      const ModelReply(
          content: '修复登录页崩溃:login.dart 在异步提交后直接刷新了界面状态,'
              '应在提交前校验表单并在 dispose 前取消监听;'
              '遇到登录类问题先跑 flutter analyze 用空安全报错定位根因。'),
    ]);
    final workspaceTools = WorkspaceToolRegistry(workspace: ws);
    final shellTools = ShellToolRegistry(executor: shellExecutor);
    final knowledgeTools = KnowledgeToolRegistry(store: store);
    final runtime1 = AgentRuntime(
      context: AgentContext(
        sessionId: 'demo-run-1',
        workspace: ws,
        project: project,
        model: model1,
        tools: CompositeToolRegistry([workspaceTools, shellTools, knowledgeTools]),
        checkpoints: checkpoints,
        hermes: HermesMemory(store: store),
        approvalPolicy:
            ShellApprovalPolicy(base: ToolPolicy.standard.toApprovalPolicy()),
      ),
      approvals: approvals,
      observer: events,
    );

    final result1 = await runtime1.run(
      [const AgentMessage(role: MessageRole.user, content: '修复登录页的崩溃问题')],
      CancelFlag(),
    );
    expect(result1, isA<AgentCompleted>());
    expect(model1.seen.first.first.role, isNot(MessageRole.system));

    // ---- [3] Shelly:统一注册表上的工具真实执行,低风险命令免审批 ----
    expect(events.started, containsAll(['read_file', 'run_command']));
    expect(shellRunner.commands, contains('flutter analyze'));
    expect(events.results['run_command'], contains('No issues found!'));
    expect(
        approvals.asked.map((c) => c.name), isNot(contains('run_command')));

    // ---- [4] Hermes:完成即自动入账(经验来源 agent,归属项目) ----
    final firstDay = await store.loadAll();
    expect(firstDay, hasLength(1));
    expect(firstDay.single.source, 'agent');
    expect(firstDay.single.project, 'login_app');
    expect(checkpoints.saved, isNotEmpty);

    // ---- [5] Shelly Git:状态读取 + 沙箱回滚 ----
    final git = GitManager(runner: _GitFakeRunner());
    expect(await git.isRepo(), isTrue);
    final status = await git.status();
    expect(status.branch, 'main');
    expect(status.changedPaths,
        containsAll(['lib/login.dart', 'lib/extra.dart']));
    final sandbox = GitSandbox(ws);
    final session = await sandbox.open();
    await ws.writeFile('lib/login.dart', 'void submit() { /* 改坏了 */ }');
    final rollback = await sandbox.restore(session);
    expect(rollback.changeCount, 1);
    expect(await ws.readFile('lib/login.dart'),
        'void submit() { /* TODO 修复登录 */ }');

    // ---- [6] Hermes Reflection:重复经验归并为一条 ----
    await store.append(KnowledgeEntry(
      id: 'k-m1',
      content: '登录崩溃先跑 flutter analyze 定位空安全根因',
      source: 'manual',
      project: 'login_app',
    ));
    await store.append(KnowledgeEntry(
      id: 'k-m2',
      content: '登录崩溃先跑 flutter analyze 定位空安全根因',
      source: 'manual',
      project: 'login_app',
    ));
    final report = await const Reflector().reflect(store, force: true);
    expect(report, isNotNull);
    expect(report!.absorbedIds, hasLength(1));
    expect(await store.loadAll(), hasLength(2));

    // ---- [7] Hermes Forgetting:陈旧低频条目让位,预算内保热点 ----
    for (var i = 0; i < 8; i++) {
      await store.append(KnowledgeEntry(
        id: 'k-fill-$i',
        content: '与登录无关的填充条目 $i:用来挤占账本预算,'
            '让遗忘扫描有东西可裁剪,这一段故意写长一点以消耗预算额度。',
        source: 'manual',
        lastTriggeredAt: DateTime.now().subtract(const Duration(days: 20)),
      ));
    }
    final forgetReport = await store.applyForgetting(
        policy: const ForgettingPolicy(maxLedgerTokens: 200));
    expect(forgetReport.droppedIds, isNotEmpty);
    var kept = await store.loadAll();
    expect(
        estimateTokens(kept.map((e) => e.content).join()),
        lessThanOrEqualTo(200));
    expect(kept.any((e) => e.content.contains('登录页崩溃')), isTrue);

    // ---- [8] DSH:声明式插件安装、信任策略首次 ask、受控执行 ----
    await ws.writeFile('dev.acme/manifest.json', _manifestText);
    final registry = DshPluginRegistry();
    final installer = DshInstaller(registry: registry, workspace: ws);
    final plugin =
        await installer.installFrom('dev.acme/manifest.json', shell: shellExecutor);
    expect(registry.lifecycleOf(plugin.manifest.id), DshLifecycle.enabled);
    expect(
        await ws.readFile('.shelly/plugins/dev.acme.buildcheck/manifest.json'),
        isNotNull);
    await DshHermesBridge(store: store)
        .recordInstalled(plugin.manifest.id, plugin.manifest.version);
    expect((await store.loadAll())
        .any((e) => e.content.contains('dev.acme.buildcheck')), isTrue);

    final trust = DshTrustPolicy();
    final dshTools = DshToolRegistry(pluginRegistry: registry, trustPolicy: trust);
    expect(trust.trustFor('vendor_build'), DshTrust.blocked);
    final pluginOut = await dshTools.execute(const ToolCall(
      id: 'p1',
      name: 'vendor_build',
      argumentsJson: '{"target":"lib/main.dart"}',
    ));
    expect(trust.trustFor('vendor_build'), DshTrust.ask);
    expect(pluginOut, contains('risk=medium'));
    expect(shellRunner.commands,
        contains('flutter build apk --debug --target=lib/main.dart'));

    // ---- [9] 第二次运行:DSH 工具与核心工具同台进入 AgentCore ----
    final model2 = _ScriptedModel([
      const ModelReply(
          toolCalls: [
            ToolCall(
                id: 'c3',
                name: 'vendor_build',
                argumentsJson: '{"target":"lib/main.dart"}')
          ]),
      const ModelReply(
          content: '已完成:参考上次登录页崩溃的教训,直接校验了表单状态,'
              '并用插件构建门禁验证构建通过,没有再走弯路。'),
    ]);
    final runtime2 = AgentRuntime(
      context: AgentContext(
        sessionId: 'demo-run-2',
        workspace: ws,
        project: project,
        model: model2,
        tools: CompositeToolRegistry(
            [workspaceTools, shellTools, dshTools, knowledgeTools]),
        checkpoints: checkpoints,
        hermes: HermesMemory(store: store),
        approvalPolicy:
            ShellApprovalPolicy(base: ToolPolicy.standard.toApprovalPolicy()),
      ),
      approvals: approvals,
      observer: events,
    );
    final result2 = await runtime2.run(
      [const AgentMessage(role: MessageRole.user, content: '继续修复登录页崩溃')],
      CancelFlag(),
    );
    expect(result2, isA<AgentCompleted>());

    // ---- [10] Hermes:相关经验作为 system 消息回注入新任务 ----
    final injected = model2.seen.first.first;
    expect(injected.role, MessageRole.system);
    expect(injected.content, contains('登录页崩溃'));

    // ---- [11] Hermes:recall 命中即累计触发频次(遗忘信号) ----
    kept = await store.loadAll();
    expect(
        kept
            .firstWhere((e) => e.content.contains('登录页崩溃'))
            .frequency,
        greaterThanOrEqualTo(1));

    // ---- [12] 账本持久化:JSONL 账本 + Markdown 投影同时落盘 ----
    expect(await ws.readFile(store.jsonlPath), isNotNull);
    expect(await ws.readFile(store.markdownPath), isNotNull);
    expect((await store.loadAll()).length, greaterThanOrEqualTo(3));
  });
}
