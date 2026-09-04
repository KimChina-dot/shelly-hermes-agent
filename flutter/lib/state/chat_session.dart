import 'dart:async';
import 'dart:io';

// Named constructor params are kept public-named for call-site readability;
// the initializing-formal rewrite would force private names at call sites.
// ignore_for_file: prefer_initializing_formals
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/agent_core.dart';
import '../core/context/context_compactor.dart';
import '../core/dsh/tool_registry.dart';
import '../core/approval_broker.dart';
import '../core/gateway/openai_gateway.dart';
import '../core/gateway/web_search.dart';
import '../core/hermes/hermes_memory.dart';
import '../core/hermes/knowledge_store.dart';
import '../core/hermes/forgetting.dart';
import '../core/hermes/knowledge_tool.dart';
import '../core/error_messages.dart';
import '../core/models.dart';
import '../core/runtime/agent_context.dart';
import '../core/runtime/agent_runtime.dart';
import '../core/runtime/tool_registry.dart';
import '../core/shell/shell_executor.dart';
import '../core/task_queue.dart';
import '../core/task_recovery.dart';
import '../core/tools/registry.dart';
import '../core/tools/workspace.dart';
import '../core/workspace/workspace_manager.dart';
import '../platform/platform_workspace.dart';
import '../platform/conversation_images.dart';
import '../platform/process_runner.dart';
import '../platform/task_service.dart';
import 'dsh_provider.dart';
import 'settings_store.dart';

/// One row in the chat transcript.
sealed class ChatEntry {
  ChatEntry() : id = 'e-${_nextId++}';

  final String id;
  static int _nextId = 0;
}

class UserEntry extends ChatEntry {
  UserEntry(this.text, {this.images = const [], this.fileNames = const []});
  final String text;

  /// Attached image data URLs, shown as thumbnails above the text.
  final List<String> images;

  /// Attached text-file names, shown as chips above the text (the file body
  /// itself only reaches the model, not the transcript).
  final List<String> fileNames;
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

/// Transient system notices rendered as a centered pill (e.g. the context
/// was auto-compacted to fit the model window).
class NoticeEntry extends ChatEntry {
  NoticeEntry(this.text);
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

  Future<void> send(
    String text, {
    List<String> images = const [],
    List<TextFileAttachment> files = const [],
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && images.isEmpty && files.isEmpty) || state.isBusy) {
      return;
    }

    final entries = [
      ...state.entries,
      UserEntry(
        trimmed,
        images: images,
        fileNames: [for (final f in files) f.name],
      ),
    ];
    state = state.copyWith(
      entries: entries,
      phase: SessionPhase.working,
      conversationId: state.conversationId ?? 'conv-${DateTime.now().millisecondsSinceEpoch}',
      clearError: true,
    );
    _startTask(
      initialMessages: [
        AgentMessage(
          role: MessageRole.user,
          content: trimmed,
          images: images,
          textFiles: files,
        ),
      ],
    );
  }

  Future<void> resume(String conversationId) async => switchTo(conversationId);

  /// The task that was running when the previous process died, if any.
  /// The UI surfaces this at startup; resuming goes through the unified
  /// runtime's `recovering` state.
  RecoveryCandidate? interruptedTask() {
    final store = _store;
    if (store == null) return null;
    return const TaskRecovery().scan(store).firstOrNull;
  }

  /// Re-runs the interrupted task from its persisted checkpoint; the unified
  /// runtime reports the `recovering` state while it catches up.
  bool recoverInterruptedTask() {
    final store = _store;
    if (store == null || state.isBusy) return false;
    final candidate = const TaskRecovery().scan(store).firstOrNull;
    if (candidate == null) return false;
    state = ChatSessionState(
      phase: SessionPhase.working,
      conversationId: candidate.record.conversationId,
      entries: _entriesFromCheckpoint(candidate.checkpoint)
        ..add(AssistantEntry(streaming: true)),
    );
    _startTask(
      initialMessages: candidate.checkpoint.messages,
      resumeFrom: candidate.checkpoint,
    );
    return true;
  }

  /// Drops the interrupted-task record without rerunning it.
  Future<void> dismissInterruptedTask() async {
    final store = _store;
    if (store == null) return;
    await store.clearActiveTask();
  }

  /// Starts a fresh conversation; false when a task is still running (the
  /// UI surfaces that instead of silently dropping the request).
  bool newConversation() {
    if (state.isBusy) return false;
    state = const ChatSessionState();
    return true;
  }

  /// Loads a past conversation from its checkpoint into the chat page;
  /// false when busy or the checkpoint is gone (e.g. deleted elsewhere).
  bool switchTo(String conversationId) {
    if (state.isBusy || _store == null) return false;
    final checkpoint = _store!.loadCheckpoint(conversationId);
    if (checkpoint == null) return false;
    state = ChatSessionState(
      phase: SessionPhase.idle,
      conversationId: conversationId,
      entries: _entriesFromCheckpoint(checkpoint),
    );
    return true;
  }

  /// Deletes the current conversation's checkpoint and resets the chat to a
  /// fresh state; false when nothing is loaded or a task is running.
  Future<bool> deleteCurrentConversation() async {
    final store = _store;
    final conversationId = state.conversationId;
    if (store == null || conversationId == null || state.isBusy) return false;
    await store.deleteConversation(conversationId);
    state = const ChatSessionState();
    return true;
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
    unawaited(store.saveActiveTask(TaskRecoveryRecord(
      conversationId: conversationId,
      taskId: taskId,
      startedAt: DateTime.now(),
    )));

    final coordinator = TaskCoordinator(
      agentFactory: (_) => _TaskRunner(
        session: this,
        store: store,
        workspaceManager: manager,
        dshTools: _ref.read(dshToolsProvider),
        conversationId: conversationId,
        imageStoreFuture: _ref
            .read(conversationImageStoreProvider.future)
            // The image cache is an optimization, never a gate: if the
            // platform is slow/unavailable (tests, odd hosts) fall back to
            // inline data URLs instead of stalling the task.
            .timeout(const Duration(seconds: 2), onTimeout: () => null),
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
            unawaited(store.clearActiveTask());
            _drainApprovals();
            _finishAssistantEntry();
            state = state.copyWith(phase: SessionPhase.idle, clearActiveTask: true);
            _persistConversation();
          case TaskState.failed:
            unawaited(TaskService.stop());
            unawaited(store.clearActiveTask());
            _drainApprovals();
            _finishAssistantEntry();
            final entries = [
              ...state.entries,
              ErrorEntry(humanizeAgentError(status.error)),
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
          entries.add(UserEntry(
            message.content,
            images: message.images,
            fileNames: [for (final f in message.textFiles) f.name],
          ));
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

  /// The model the current config will use, recorded on the conversation
  /// summary for reference. The config is re-read per task, so a switch
  /// applies from the next send.
  String? _modelIdFrom(SettingsStore store) {
    final config = store.loadModelConfig();
    return config.isComplete ? config.model : null;
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
          modelId: _modelIdFrom(store),
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

  void notifyContextCompacted(ContextCompacted event) {
    state = state.copyWith(
      entries: [
        ...state.entries,
        NoticeEntry(
          '上下文已自动压缩:${event.tokensBefore ~/ 1000}K → '
          '${event.tokensAfter ~/ 1000}K tokens,折叠 ${event.droppedMessages} 条'
          '${event.usedModelSummary ? '' : '(模型摘要失败,使用占位摘要)'}',
        ),
      ],
    );
  }

  static String _titleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 24 ? flat : '${flat.substring(0, 24)}…';
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
    required DshToolRegistry dshTools,
    required String conversationId,
    Future<ConversationImageStore?>? imageStoreFuture,
  })  : _session = session,
        _store = store,
        _workspaceManager = workspaceManager,
        _dshTools = dshTools,
        _conversationId = conversationId,
        _imageStoreFuture = imageStoreFuture;

  final ChatSessionController _session;
  final SettingsStore _store;
  final WorkspaceManager _workspaceManager;
  final DshToolRegistry _dshTools;
  final String _conversationId;

  /// Persists attached images to disk so checkpoints keep short file paths
  /// instead of inline base64; null keeps the old inline behavior.
  final Future<ConversationImageStore?>? _imageStoreFuture;

  /// Replaces inline data-URL images with on-disk file paths. Failures keep
  /// the original data URL — an attachment must never break a send.
  Future<List<AgentMessage>> _persistImages(List<AgentMessage> messages) async {
    final ConversationImageStore? imageStore;
    try {
      imageStore = await (_imageStoreFuture ?? Future.value(null));
    } catch (_) {
      return messages;
    }
    if (imageStore == null) return messages;
    var changed = false;
    final persisted = <AgentMessage>[];
    for (final message in messages) {
      if (message.images.isEmpty) {
        persisted.add(message);
        continue;
      }
      final paths = <String>[];
      for (final url in message.images) {
        if (!url.startsWith('data:')) {
          paths.add(url);
          continue;
        }
        try {
          paths.add(await imageStore.save(url));
          changed = true;
        } catch (_) {
          paths.add(url);
        }
      }
      persisted.add(AgentMessage(
        role: message.role,
        content: message.content,
        toolCallId: message.toolCallId,
        toolCalls: message.toolCalls,
        textFiles: message.textFiles,
        images: paths,
      ));
    }
    return changed ? persisted : messages;
  }

  @override
  Future<AgentResult> run(
    List<AgentMessage> messages,
    CancellationSignal cancellation, {
    AgentCheckpoint? resumeFrom,
  }) async {
    // Fresh sends only: a resume's messages already hold file paths.
    final preparedMessages =
        resumeFrom == null ? await _persistImages(messages) : messages;
    final config = _store.loadModelConfig();
    final profile = _store.activeProfile();
    final memorySettings = _store.loadMemorySettings();
    final workspace = _workspaceManager.workspace;
    final project = await _workspaceManager.detectProject();
    final workspaceTools = WorkspaceToolRegistry(workspace: workspace);
    final knowledgeStore = HermesKnowledgeStore(
      workspace: workspace,
      project: project.name,
      maxRecallEntries: memorySettings.recallEntries,
      maxRecallTokens: memorySettings.recallTokens,
    );
    final shellRunner = createProcessRunner();
    final registry = CompositeToolRegistry([
      workspaceTools,
      ShellToolRegistry(
        executor: ShellExecutor(runner: shellRunner),
      ),
      KnowledgeToolRegistry(store: knowledgeStore),
      _dshTools,
    ]);
    final ModelGateway model = config.isComplete
        ? OpenAiCompatibleGateway(
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
            model: config.model,
            tools: registry.openAiToolsJson(),
            bodyDecorator: webSearchBodyDecorator(
              enabled: config.webSearchEnabled,
              baseUrl: config.baseUrl,
            ),
          )
        : DemoModelGateway();

    // Auto-compact long conversations against the model's context window;
    // the same gateway produces the summary (failures degrade in-engine).
    final ContextCompactor? compactor = config.isComplete
        ? ContextCompactor(
            windowTokens: config.effectiveContextWindow,
            summarizer: (transcript) async => (await model.complete([
                  const AgentMessage(
                    role: MessageRole.system,
                    content: '你是会话摘要器。把以下对话记录压缩为一段简明摘要,'
                        '保留:任务目标、已完成的步骤、关键文件与结论、待办事项。'
                        '只输出摘要正文,不要评论。',
                  ),
                  AgentMessage(role: MessageRole.user, content: transcript),
                ]))
                    .content,
          )
        : null;

    final runtime = AgentRuntime(
      context: AgentContext(
        sessionId: _conversationId,
        workspace: workspace,
        model: model,
        tools: registry,
        checkpoints: _StoreCheckpoints(_store, _conversationId),
        project: project,
        contextCompactor: compactor,
        hermes: HermesMemory(
          store: knowledgeStore,
          autoCapture: config.isComplete && profile.autoCapture,
          maxAutoEntries: memorySettings.maxAutoEntries,
          forgettingPolicy: ForgettingPolicy(
            maxLedgerTokens: memorySettings.maxLedgerTokens,
            activeDays: memorySettings.activeDays,
            coolingDays: memorySettings.coolingDays,
            frequencyFloor: memorySettings.frequencyFloor,
          ),
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
            ...preparedMessages,
          ]
        : preparedMessages;
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
      case ContextCompacted():
        _session.notifyContextCompacted(event);
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

/// Whether the workspace is writable for real: always true off Android;
/// on Android true once a SAF directory is granted, false while running
/// in the in-memory demo sandbox. Invalidate after picking a directory.
final workspaceAuthorizedProvider = FutureProvider.autoDispose<bool>((ref) async {
  final workspace = ref.watch(workspaceProvider);
  if (workspace is ResilientWorkspace) {
    await workspace.refreshAuthorization();
    return workspace.authorized.value;
  }
  return true;
});

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

/// On-disk cache for attached conversation images. Null when the platform
/// cannot provide a temp directory (tests, degraded hosts) — the session
/// then keeps data URLs inline instead of file paths.
final conversationImageStoreProvider =
    FutureProvider<ConversationImageStore?>((ref) async {
  try {
    final temp = await getTemporaryDirectory();
    return ConversationImageStore(
      Directory('${temp.path}${Platform.pathSeparator}shelly_images'),
    );
  } catch (_) {
    return null;
  }
});

final chatSessionProvider =
    StateNotifierProvider<ChatSessionController, ChatSessionState>(
  (ref) => ChatSessionController(ref),
);
