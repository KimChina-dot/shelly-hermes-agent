import 'dart:async';

// Named constructor params are kept public-named for call-site readability;
// the initializing-formal rewrite would force private names at call sites.
// ignore_for_file: prefer_initializing_formals
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/agent_core.dart';
import '../core/approval_broker.dart';
import '../core/gateway/openai_gateway.dart';
import '../core/hermes/hermes_memory.dart';
import '../core/hermes/knowledge_store.dart';
import '../core/hermes/knowledge_tool.dart';
import '../core/models.dart';
import '../core/runtime/agent_context.dart';
import '../core/runtime/agent_runtime.dart';
import '../core/runtime/tool_registry.dart';
import '../core/shell/shell_executor.dart';
import '../core/task_queue.dart';
import '../core/tools/registry.dart';
import '../core/tools/workspace.dart';
import '../core/workspace/workspace_manager.dart';
import '../platform/platform_workspace.dart';
import '../platform/process_runner.dart';
import '../platform/task_service.dart';
import 'settings_store.dart';

/// One row in the chat transcript.
sealed class ChatEntry {
  ChatEntry() : id = 'e-${_nextId++}';

  final String id;
  static int _nextId = 0;
}

class UserEntry extends ChatEntry {
  UserEntry(this.text);
  final String text;
}

class AssistantEntry extends ChatEntry {
  AssistantEntry({this.text = '', this.streaming = false});

  final String text;
  final bool streaming;

  AssistantEntry copyWith({String? text, bool? streaming}) => AssistantEntry(
        text: text ?? this.text,
        streaming: streaming ?? this.streaming,
      );
}

enum ToolRunStatus { running, succeeded, failed }

class ToolEntry extends ChatEntry {
  ToolEntry({required this.call, this.status = ToolRunStatus.running});

  final ToolCall call;
  ToolRunStatus status;
  String? result;
  int durationMillis = 0;
}

class ErrorEntry extends ChatEntry {
  ErrorEntry(this.text);
  final String text;
}

enum SessionPhase { idle, working, waitingApproval }

class ChatSessionState {
  const ChatSessionState({
    this.entries = const [],
    this.phase = SessionPhase.idle,
    this.activeTaskId,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.conversationId,
    this.error,
  });

  final List<ChatEntry> entries;
  final SessionPhase phase;
  final String? activeTaskId;
  final int inputTokens;
  final int outputTokens;

  /// Non-null while a conversation is loaded (new or resumed).
  final String? conversationId;

  final String? error;

  bool get isBusy => phase != SessionPhase.idle;

  ChatSessionState copyWith({
    List<ChatEntry>? entries,
    SessionPhase? phase,
    String? activeTaskId,
    Object? clearActiveTask = _sentinel,
    int? inputTokens,
    int? outputTokens,
    String? conversationId,
    String? error,
    bool clearError = false,
  }) {
    return ChatSessionState(
      entries: entries ?? this.entries,
      phase: phase ?? this.phase,
      activeTaskId: clearActiveTask == _sentinel ? activeTaskId ?? this.activeTaskId : activeTaskId,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      conversationId: conversationId ?? this.conversationId,
      error: clearError ? null : error ?? this.error,
    );
  }

  static const _sentinel = Object();
}

/// Owns one running conversation: builds an AgentCore per user message,
/// maps engine events onto chat entries, and exposes broker-driven
/// approval state for the approval modal.
class ChatSessionController extends StateNotifier<ChatSessionState> {
  ChatSessionController(this._ref) : super(const ChatSessionState()) {
    _broker.launcher = _onApprovalRequested;
  }

  final Ref _ref;
  final ApprovalBroker _broker = ApprovalBroker();

  SettingsStore? _store;
  TaskCoordinator? _activeCoordinator;

  ApprovalBroker get broker => _broker;

  /// Wires persistence once SharedPreferences is ready.
  void attach(SettingsStore store) {
    _store = store;
  }

  void _onApprovalRequested(PendingApproval approval) {
    state = state.copyWith(phase: SessionPhase.waitingApproval);
    final queue = _ref.read(approvalQueueProvider);
    _ref.read(approvalQueueProvider.notifier).state = [...queue, approval];
    _approvalRouter.route(approval);
  }

  final _ApprovalRouter _approvalRouter = _ApprovalRouter();

  /// Routes approval requests to whoever renders the approval modal. The
  /// chat page registers itself here on build.
  void setApprovalHandler(void Function(PendingApproval approval)? handler) {
    _approvalRouter.handler = handler;
    // Surface an approval that arrived before a handler was attached.
    final pending = _approvalRouter.pending;
    if (pending != null) handler?.call(pending);
  }

  /// Delivers the user's decision for one queued approval request.
  void resolveApproval(PendingApproval approval, ApprovalDecision decision) {
    final queue = [..._ref.read(approvalQueueProvider)]..remove(approval);
    _ref.read(approvalQueueProvider.notifier).state = queue;
    if (!approval.decision.isCompleted) approval.decision.complete(decision);
    if (queue.isEmpty && state.phase == SessionPhase.waitingApproval) {
      state = state.copyWith(phase: SessionPhase.working);
    }
  }

  /// Completes any still-queued approvals with a rejection when the task
  /// ends abnormally, so no UI listener is left hanging.
  void _drainApprovals() {
    final queue = _ref.read(approvalQueueProvider);
    for (final approval in queue) {
      if (!approval.decision.isCompleted) {
        approval.decision.complete(ApprovalDecision.reject);
      }
    }
    if (queue.isNotEmpty) {
      _ref.read(approvalQueueProvider.notifier).state = const [];
    }
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.isBusy) return;

    final entries = [...state.entries, UserEntry(trimmed)];
    state = state.copyWith(
      entries: entries,
      phase: SessionPhase.working,
      conversationId: state.conversationId ?? 'conv-${DateTime.now().millisecondsSinceEpoch}',
      clearError: true,
    );
    _startTask(initialMessages: [AgentMessage(role: MessageRole.user, content: trimmed)]);
  }

  Future<void> resume(String conversationId) async {
    if (state.isBusy || _store == null) return;
    final checkpoint = _store!.loadCheckpoint(conversationId);
    if (checkpoint == null) return;
    state = ChatSessionState(
      phase: SessionPhase.idle,
      conversationId: conversationId,
      entries: _entriesFromCheckpoint(checkpoint),
    );
  }

  void newConversation() {
    if (state.isBusy) return;
    state = const ChatSessionState();
  }

  void cancel() {
    final taskId = state.activeTaskId;
    if (taskId != null) _activeCoordinator?.stop(taskId);
  }

  void _startTask({required List<AgentMessage> initialMessages, AgentCheckpoint? resumeFrom}) {
    final store = _store;
    if (store == null) {
      state = state.copyWith(
        phase: SessionPhase.idle,
        error: '设置尚未加载完成,请稍候重试',
      );
      return;
    }
    final manager = _ref.read(workspaceManagerProvider);
    final conversationId = state.conversationId ?? '';

    final taskId = 'task-${DateTime.now().millisecondsSinceEpoch}';
    final entries = [...state.entries, AssistantEntry(streaming: true)];
    state = state.copyWith(entries: entries, activeTaskId: taskId);
    unawaited(TaskService.start());

    final coordinator = TaskCoordinator(
      agentFactory: (_) => _TaskRunner(
        session: this,
        store: store,
        workspaceManager: manager,
        conversationId: conversationId,
      ),
      listener: (status) {
        final history = _ref.read(taskHistoryProvider);
        _ref.read(taskHistoryProvider.notifier).state = [
          ...history.take(49),
          status,
        ];
        switch (status.state) {
          case TaskState.completed:
          case TaskState.stopped:
            unawaited(TaskService.stop());
            _drainApprovals();
            _finishAssistantEntry();
            state = state.copyWith(phase: SessionPhase.idle, clearActiveTask: true);
            _persistConversation();
          case TaskState.failed:
            unawaited(TaskService.stop());
            _drainApprovals();
            _finishAssistantEntry();
            final entries = [
              ...state.entries,
              ErrorEntry('任务失败:${_brief(status.error)}'),
            ];
            state = state.copyWith(
              entries: entries,
              phase: SessionPhase.idle,
              clearActiveTask: true,
            );
          default:
            break;
        }
      },
    );
    coordinator.start(
      taskId,
      initialMessages,
      resumeFrom: resumeFrom,
    );
    _activeCoordinator = coordinator;
  }

  void _finishAssistantEntry() {
    final entries = [...state.entries];
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (entry is AssistantEntry && entry.streaming) {
        entries[i] = entry.copyWith(streaming: false);
      }
    }
    state = state.copyWith(entries: entries);
  }

  List<ChatEntry> _entriesFromCheckpoint(AgentCheckpoint checkpoint) {
    final entries = <ChatEntry>[];
    final openCalls = <String, ToolEntry>{};
    for (final message in checkpoint.messages) {
      for (final call in message.toolCalls) {
        // Historical tool calls finished before the checkpoint was taken;
        // their result text arrives with the matching tool message.
        final entry = ToolEntry(call: call);
        openCalls[call.id] = entry;
        entries.add(entry);
      }
      switch (message.role) {
        case MessageRole.user:
          entries.add(UserEntry(message.content));
        case MessageRole.assistant:
          if (message.content.isNotEmpty) {
            entries.add(AssistantEntry(text: message.content));
          }
        case MessageRole.tool:
          final entry = message.toolCallId == null
              ? null
              : openCalls[message.toolCallId];
          if (entry != null) {
            entry
              ..status = ToolRunStatus.succeeded
              ..result = message.content;
          }
        case MessageRole.system:
          break;
      }
    }
    return entries;
  }

  void _persistConversation() {
    final store = _store;
    final conversationId = state.conversationId;
    if (store == null || conversationId == null) return;
    final checkpoint = store.loadCheckpoint(conversationId);
    final userEntries = state.entries.whereType<UserEntry>().toList();
    if (userEntries.isEmpty) return;
    final summaries = [...store.loadConversations()]
      ..removeWhere((c) => c.id == conversationId)
      ..insert(
        0,
        ConversationSummary(
          id: conversationId,
          title: _titleFrom(userEntries.first.text),
          updatedAt: DateTime.now(),
          messageCount: checkpoint?.messages.length ?? state.entries.length,
        ),
      );
    unawaited(store.saveConversations(summaries.take(100).toList()));
  }

  void appendDelta(String text) {
    final entries = [...state.entries];
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (entry is AssistantEntry) {
        entries[i] = entry.copyWith(text: entry.text + text);
        state = state.copyWith(entries: entries);
        return;
      }
    }
  }

  void upsertToolEntry(ToolStarted started, {ToolFinished? finished}) {
    final entries = [...state.entries];
    ToolEntry? existing;
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i] is ToolEntry && (entries[i] as ToolEntry).call.id == started.toolCallId) {
        existing = entries[i] as ToolEntry;
        break;
      }
    }
    if (existing == null) {
      final entry = ToolEntry(call: ToolCall(
        id: started.toolCallId,
        name: started.toolName,
        argumentsJson: started.argumentsJson,
      ));
      if (finished != null) {
        entry.status = finished.succeeded ? ToolRunStatus.succeeded : ToolRunStatus.failed;
        entry.result = finished.result;
        entry.durationMillis = finished.durationMillis;
      }
      // Tool work precedes the assistant's final reply in the transcript:
      // insert before the streaming assistant entry, not after it.
      var insertAt = entries.length;
      for (var i = entries.length - 1; i >= 0; i--) {
        if (entries[i] is AssistantEntry) {
          insertAt = i;
        } else {
          break;
        }
      }
      entries.insert(insertAt, entry);
    } else if (finished != null) {
      existing
        ..status = finished.succeeded ? ToolRunStatus.succeeded : ToolRunStatus.failed
        ..result = finished.result
        ..durationMillis = finished.durationMillis;
    }
    state = state.copyWith(entries: entries);
  }

  void recordTokens(int input, int output) {
    state = state.copyWith(
      inputTokens: state.inputTokens + input,
      outputTokens: state.outputTokens + output,
    );
  }

  static String _titleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 24 ? flat : '${flat.substring(0, 24)}…';
  }

  static String _brief(Object? error) {
    final text = error?.toString() ?? '未知错误';
    return text.length <= 120 ? text : '${text.substring(0, 120)}…';
  }
}

/// Bridges the engine's approval requests to the UI layer. The approval
/// modal registers a handler; requests arriving before registration are
/// held and re-emitted on attach.
class _ApprovalRouter {
  void Function(PendingApproval approval)? handler;
  PendingApproval? _pending;

  PendingApproval? get pending => _pending;

  void route(PendingApproval approval) {
    if (handler == null) {
      _pending = approval;
    } else {
      handler!(approval);
    }
  }
}

class _TaskRunner implements AgentTaskRunner {
  _TaskRunner({
    required ChatSessionController session,
    required SettingsStore store,
    required WorkspaceManager workspaceManager,
    required String conversationId,
  })  : _session = session,
        _store = store,
        _workspaceManager = workspaceManager,
        _conversationId = conversationId;

  final ChatSessionController _session;
  final SettingsStore _store;
  final WorkspaceManager _workspaceManager;
  final String _conversationId;

  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    final config = _store.loadModelConfig();
    final profile = _store.activeProfile();
    final workspace = _workspaceManager.workspace;
    final project = await _workspaceManager.detectProject();
    final workspaceTools = WorkspaceToolRegistry(workspace: workspace);
    final knowledgeStore = HermesKnowledgeStore(
      workspace: workspace,
      project: project.name,
    );
    final shellRunner = createProcessRunner();
    final registry = CompositeToolRegistry([
      workspaceTools,
      ShellToolRegistry(
        executor: ShellExecutor(runner: shellRunner),
      ),
      KnowledgeToolRegistry(store: knowledgeStore),
    ]);
    final ModelGateway model = config.isComplete
        ? OpenAiCompatibleGateway(
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            model: config.model,
            tools: registry.openAiToolsJson(),
          )
        : DemoModelGateway();

    final runtime = AgentRuntime(
      context: AgentContext(
        sessionId: _conversationId,
        workspace: workspace,
        model: model,
        tools: registry,
        checkpoints: _StoreCheckpoints(_store, _conversationId),
        project: project,
        hermes: HermesMemory(
          store: knowledgeStore,
          autoCapture: config.isComplete && profile.autoCapture,
        ),
        limits: AgentLimits(
          maxRounds: profile.maxRounds,
          maxToolCalls: profile.maxToolCalls,
        ),
        approvalPolicy: ShellApprovalPolicy(
          base: ToolPolicy.standard.toApprovalPolicy(),
        ),
      ),
      approvals: _session.broker,
      observer: _SessionObserver(_session),
    );

    // Persona prompt opens every fresh task; a resume keeps its checkpoint.
    final effectiveMessages = resumeFrom == null && profile.systemPrompt.isNotEmpty
        ? [
            AgentMessage(role: MessageRole.system, content: profile.systemPrompt),
            ...messages,
          ]
        : messages;
    return runtime.run(effectiveMessages, cancellation, resumeFrom: resumeFrom);
  }
}

class _SessionObserver implements AgentObserver {
  _SessionObserver(this._session);

  final ChatSessionController _session;

  @override
  void onEvent(AgentEvent event) {
    switch (event) {
      case ModelStarted():
        break;
      case ModelDelta():
        _session.appendDelta(event.text);
      case ModelFinished():
        _session.recordTokens(event.inputTokens, event.outputTokens);
      case ApprovalWaiting():
        break;
      case ApprovalFinished():
        break;
      case ToolStarted():
        _session.upsertToolEntry(event);
      case ToolFinished():
        _session.upsertToolEntry(
          ToolStarted(event.toolCallId, event.toolName),
          finished: event,
        );
    }
  }
}

class _StoreCheckpoints implements CheckpointStore {
  _StoreCheckpoints(this._store, this._conversationId);

  final SettingsStore _store;
  final String _conversationId;

  @override
  Future<void> save(AgentCheckpoint checkpoint) async {
    if (_conversationId.isEmpty) return;
    await _store.saveCheckpoint(_conversationId, checkpoint);
  }
}

/// Demo model used when no API endpoint is configured. Streams a canned
/// reply and, on trigger phrases, drives the real tool/approval pipeline so
/// the UI can be exercised end-to-end without network access.
class DemoModelGateway implements StreamingModelGateway {
  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async =>
      _replyFor(messages);

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final reply = _replyFor(messages);
    if (reply.toolCalls.isNotEmpty) {
      // Tool-call replies arrive without streamed text.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return reply;
    }
    final text = reply.content;
    for (var i = 0; i < text.length; i += 2) {
      final end = (i + 2).clamp(0, text.length);
      onDelta(text.substring(i, end));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    return reply;
  }

  ModelReply _replyFor(List<AgentMessage> messages) {
    final userTexts = [
      for (final m in messages)
        if (m.role == MessageRole.user) m.content,
    ];
    final lastUser = userTexts.isEmpty ? '' : userTexts.last;
    final toolResults = messages
        .where((m) => m.role == MessageRole.tool)
        .toList();

    if (lastUser.contains('演示补丁')) {
      if (toolResults.isEmpty) {
        return const ModelReply(toolCalls: [
          ToolCall(
            id: 'demo-w1',
            name: 'write_file',
            argumentsJson:
                '{"path":"demo/notes.md","content":"第一行\\n第二行\\n第三行\\n第四行\\n"}',
          ),
        ]);
      }
      if (toolResults.length == 1) {
        return const ModelReply(toolCalls: [
          ToolCall(
            id: 'demo-p1',
            name: 'apply_patch',
            argumentsJson:
                '{"path":"demo/notes.md","patch":"@@ -1,2 +1,2 @@\\n 第一行\\n-第二行\\n+第二行(已修改)\\n@@ -3,2 +3,2 @@\\n 第三行\\n-第四行\\n+第四行(也修改了)"}',
          ),
        ]);
      }
      return const ModelReply(
          content: '演示完成:我写入了 `demo/notes.md` 并应用了一个包含两个 hunk 的补丁,'
              '每个 hunk 都需要你单独确认。');
    }
    if (lastUser.contains('演示工具')) {
      if (toolResults.isEmpty) {
        return const ModelReply(toolCalls: [
          ToolCall(id: 'demo-t1', name: 'list_files', argumentsJson: '{}'),
        ]);
      }
      return const ModelReply(content: '演示完成:`list_files` 是只读工具,'
          '无需审批即自动执行。结果已显示在上方工具卡片中。');
    }

    return const ModelReply(
      content: '这是**演示模式**的回复(未配置模型接口)。\n\n'
          '你可以在「我的 → 模型配置」中填入任意 OpenAI 兼容接口地址、密钥和模型名,'
          '对话将改为真实流式生成。\n\n试试发送:\n\n'
          '- `演示工具` —— 触发一次自动执行的只读工具\n'
          '- `演示补丁` —— 触发一次逐 hunk 审批的代码补丁\n\n'
          '```dart\nvoid main() => print("Hello, Shelly!");\n```',
    );
  }
}

/// SAF-backed workspace on Android, in-memory storage on the dev harness.
final workspaceProvider = Provider<Workspace>((ref) => createWorkspace());

/// Unified workspace entry: project detection, snapshots, root persistence.
final workspaceManagerProvider = Provider<WorkspaceManager>(
  (ref) => WorkspaceManager(workspace: ref.watch(workspaceProvider)),
);

/// Approval requests awaiting a user decision, in engine order. The engine
/// awaits each decision before issuing the next request, so apply_patch
/// hunks arrive one at a time and the approval UI drains this queue FIFO.
final approvalQueueProvider = StateProvider<List<PendingApproval>>(
  (ref) => const [],
);

/// Rolling log of task status transitions (newest last), consumed by the
/// tasks page. Capped at 50 entries.
final taskHistoryProvider = StateProvider<List<TaskStatus>>(
  (ref) => const [],
);

final chatSessionProvider =
    StateNotifierProvider<ChatSessionController, ChatSessionState>(
  (ref) => ChatSessionController(ref),
);
