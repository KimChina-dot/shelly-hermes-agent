import 'dart:async';
import 'dart:io';

// Named constructor params are kept public-named for call-site readability;
// the initializing-formal rewrite would force private names at call sites.
// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/agent_core.dart';
import '../core/context/context_compactor.dart';
import '../core/dsh/tool_registry.dart';
import '../core/approval_broker.dart';
import '../core/crash/crash_log_store.dart';
import '../core/gateway/openai_gateway.dart';
import '../core/gateway/web_search.dart';
import '../core/hermes/hermes_memory.dart';
import '../core/hermes/knowledge_store.dart';
import '../core/hermes/forgetting.dart';
import '../core/hermes/knowledge_tool.dart';
import '../core/error_messages.dart';
import '../core/mcp/bridge_client.dart';
import '../core/mcp/mcp_guard.dart';
import '../core/mcp/mcp_tool_registry.dart';
import '../core/memory/memory_extractor.dart';
import '../core/memory/memory_store.dart';
import '../core/runtime/hardened_tool_executor.dart';
import '../core/models.dart';
import '../core/runtime/agent_context.dart';
import '../core/runtime/agent_runtime.dart';
import '../core/runtime/tool_registry.dart';
import '../core/shell/shell_executor.dart';
import '../core/task_queue.dart';
import '../core/task_recovery.dart';
import '../core/tools/registry.dart';
import '../core/tools/memory_search_tool.dart';
import '../core/tools/notes_tool.dart';
import '../core/tools/terminal_tools.dart';
import '../core/tools/workspace.dart';
import '../core/workspace/workspace_manager.dart';
import '../platform/platform_workspace.dart';
import '../platform/conversation_images.dart';
import '../platform/process_runner.dart';
import '../platform/task_service.dart';
import 'dsh_provider.dart';
import 'settings_store.dart';
import 'usage_stats.dart';

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
    this.queuedMessages = const [],
  });

  final List<ChatEntry> entries;
  final SessionPhase phase;
  final String? activeTaskId;
  final int inputTokens;
  final int outputTokens;

  /// Non-null while a conversation is loaded (new or resumed).
  final String? conversationId;

  final String? error;

  /// PHASE 51 steering-lite: messages composed while a task was busy. They
  /// are parked here oldest-first (capped at
  /// [ChatSessionController.maxQueuedMessages]) and auto-sent FIFO, one per
  /// task completion. Immutable copy semantics like [entries]: every update
  /// stores a freshly built list.
  final List<String> queuedMessages;

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
    List<String>? queuedMessages,
  }) {
    return ChatSessionState(
      entries: entries ?? this.entries,
      phase: phase ?? this.phase,
      activeTaskId: clearActiveTask == _sentinel ? activeTaskId ?? this.activeTaskId : activeTaskId,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      conversationId: conversationId ?? this.conversationId,
      error: clearError ? null : error ?? this.error,
      queuedMessages: queuedMessages ?? this.queuedMessages,
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

  /// PHASE 51: upper bound on parked steering messages; the oldest is
  /// dropped when the cap is exceeded.
  static const int maxQueuedMessages = 5;

  /// True while a dequeued message is being dispatched through [send].
  /// Guards the completion observer against re-entrancy: the dequeue of the
  /// NEXT queued message must wait for the dequeued one's own completion,
  /// never chain inside the same callback.
  bool _dequeueing = false;

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

  /// PHASE 48 (OpenAI HITL `always_approve`): approves [approval] and records
  /// its tool NAME in the broker's session-scoped allow set, so the same tool
  /// name is not asked again for the rest of this session. Mirrors the
  /// [resolveApproval] approve flow exactly; the allow set is in-memory only
  /// and dies with the controller. UI hook left to the controller: call this
  /// from the approval sheet's 「本次会话不再询问」 action.
  void approveAlwaysAndResume(PendingApproval approval) {
    _broker.approveAlways(approval.call);
    resolveApproval(approval, ApprovalDecision.approve);
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
    if ((trimmed.isEmpty && images.isEmpty && files.isEmpty)) {
      return;
    }
    // PHASE 51 steering-lite: while a task is running the message does not
    // die — it parks in the queue and auto-sends when the task completes.
    // Only text steers; attachments keep requiring an idle composer.
    if (state.isBusy) {
      if (trimmed.isEmpty || images.isNotEmpty || files.isNotEmpty) return;
      _enqueueMessage(trimmed);
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

  /// PHASE 51: parks [text] in the steering queue while busy — FIFO with a
  /// [maxQueuedMessages] cap, dropping the OLDEST entry when full.
  void _enqueueMessage(String text) {
    final queue = [...state.queuedMessages, text];
    if (queue.length > maxQueuedMessages) {
      queue.removeRange(0, queue.length - maxQueuedMessages);
    }
    state = state.copyWith(queuedMessages: queue);
  }

  /// PHASE 51: removes the queued message at [index] (user tapped the chip's
  /// dismiss X). No-op when the index is out of range.
  void removeQueuedMessage(int index) {
    if (index < 0 || index >= state.queuedMessages.length) return;
    final queue = [...state.queuedMessages]..removeAt(index);
    state = state.copyWith(queuedMessages: queue);
  }

  /// PHASE 51: one steering message per completed task. Pops the FIRST
  /// queued message and re-dispatches it through [send] with full semantics
  /// (fresh user entry, persona, persistence, its own completion → the next
  /// dequeue). Called from the completion observer only after the session is
  /// idle and no approval is pending; [_dequeueing] keeps the re-entrant
  /// [send] from triggering another dequeue inside the same callback.
  void _dequeueNext() {
    if (_dequeueing || state.queuedMessages.isEmpty || state.isBusy) return;
    _dequeueing = true;
    try {
      final next = state.queuedMessages.first;
      state = state.copyWith(
        queuedMessages: [...state.queuedMessages]..removeAt(0),
      );
      unawaited(send(next));
    } finally {
      _dequeueing = false;
    }
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
    // PHASE 51: a fresh state also drops parked steering messages — they
    // belong to the old conversation.
    state = const ChatSessionState();
    return true;
  }

  /// Loads a past conversation from its checkpoint into the chat page;
  /// false when busy or the checkpoint is gone (e.g. deleted elsewhere).
  bool switchTo(String conversationId) {
    if (state.isBusy || _store == null) return false;
    final checkpoint = _store!.loadCheckpoint(conversationId);
    if (checkpoint == null) return false;
    // PHASE 51: parked steering messages belong to the previous context.
    state = ChatSessionState(
      phase: SessionPhase.idle,
      conversationId: conversationId,
      entries: _entriesFromCheckpoint(checkpoint),
      queuedMessages: const [],
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

  /// PHASE 50: drops the trailing assistant reply (and any tool/error rows
  /// after it) and re-runs the SAME user message — both the in-memory
  /// transcript and the persisted checkpoint are truncated back to the last
  /// user turn. No-op (returns false) while a task is running or when there
  /// is no user message to re-dispatch.
  bool regenerateLast() => _resendLastUserTurn();

  /// PHASE 50: like [regenerateLast], but the last user message's text is
  /// replaced by [newText] before the task re-runs. No-op (returns false)
  /// while busy, when the text is blank, or when there is no user message.
  bool editAndResend(String newText) =>
      _resendLastUserTurn(replacementText: newText);

  /// Shared regeneration core: trims everything after the last [UserEntry],
  /// optionally swapping its text for the edited version, then re-dispatches
  /// the truncated checkpoint via the [AgentCheckpoint] resume path so
  /// earlier turns (and the original persona/recall system messages) stay in
  /// context. The busy-guard runs first: nothing is touched mid-task.
  bool _resendLastUserTurn({String? replacementText}) {
    if (state.isBusy) return false;
    final store = _store;
    if (store == null) return false;
    final entries = [...state.entries];
    final lastUserIndex = entries.lastIndexWhere((e) => e is UserEntry);
    if (lastUserIndex < 0) return false;
    final userEntry = entries[lastUserIndex] as UserEntry;
    final edited = replacementText?.trim();
    if (replacementText != null && (edited == null || edited.isEmpty)) {
      return false;
    }

    // Persisted transcript first: cut back to (and including) the last user
    // message so a crash mid-regeneration can never resurrect the dropped
    // reply from the old checkpoint.
    final conversationId = state.conversationId;
    final checkpoint =
        conversationId == null ? null : store.loadCheckpoint(conversationId);
    List<AgentMessage> messages;
    AgentCheckpoint? resumeFrom;
    if (checkpoint != null) {
      final lastUserMessage = checkpoint.messages
          .lastIndexWhere((m) => m.role == MessageRole.user);
      if (lastUserMessage < 0) return false;
      messages = checkpoint.messages.sublist(0, lastUserMessage + 1);
      if (edited != null) {
        final original = messages.last;
        messages[messages.length - 1] = AgentMessage(
          role: MessageRole.user,
          content: edited,
          images: original.images,
          textFiles: original.textFiles,
        );
      }
      resumeFrom = AgentCheckpoint(
        messages: messages,
        // A regeneration is a fresh run of the turn: budgets reset.
        round: 0,
        consumedTokens: 0,
        toolCalls: 0,
      );
      unawaited(store.saveCheckpoint(conversationId!, resumeFrom));
    } else {
      // No persisted checkpoint (degraded hosts): rebuild the turn from the
      // entry itself; a fresh send re-applies the persona and re-persists
      // inline images.
      messages = [
        AgentMessage(
          role: MessageRole.user,
          content: edited ?? userEntry.text,
          images: userEntry.images,
        ),
      ];
    }

    final kept = entries.sublist(0, lastUserIndex + 1);
    if (edited != null) {
      kept[lastUserIndex] = UserEntry(
        edited,
        images: userEntry.images,
        fileNames: userEntry.fileNames,
      );
    }
    state = state.copyWith(
      entries: kept,
      phase: SessionPhase.working,
      clearError: true,
    );
    _startTask(initialMessages: messages, resumeFrom: resumeFrom);
    return true;
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
        chatGatewayOverride: _ref.read(chatGatewayOverrideProvider),
        imageStoreFuture: _ref
            .read(conversationImageStoreProvider.future)
            // The image cache is an optimization, never a gate: if the
            // platform is slow/unavailable (tests, odd hosts) fall back to
            // inline data URLs instead of stalling the task.
            .timeout(const Duration(seconds: 2), onTimeout: () => null),
        memoryStoreFuture: _ref
            .read(memoryStoreProvider.future)
            // Same "never a gate" contract: a slow or missing prefs backend
            // skips the memory block instead of stalling the send.
            .timeout(const Duration(seconds: 2), onTimeout: () => null),
        crashLogFuture: _ref
            .read(crashLogProvider.future)
            .then<CrashLogStore?>((store) => store)
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
            // PHASE 51 steering-lite: the session is idle and no approval is
            // pending (drained above) — a queued message now goes out, one
            // per completion. Its own completion dequeues the next one.
            _dequeueNext();
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

  /// Persists one completed model round into the local usage statistics
  /// (PHASE 40). Best-effort: any failure is swallowed so chat never breaks.
  void recordUsage(int promptTokens, int completionTokens,
      {int cachedTokens = 0}) {
    final store = _store;
    final modelId =
        store == null ? null : _modelIdFrom(store) ?? 'demo';
    unawaited(() async {
      try {
        final stats = await _ref.read(usageStatsProvider.future);
        await stats.recordUsage(
          modelId: modelId ?? 'demo',
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          cachedTokens: cachedTokens,
        );
      } catch (_) {
        // Usage stats are a nice-to-have; a broken store must never
        // surface as a chat error.
      }
    }());
  }

  /// Best-effort automatic long-term memory (PHASE 41). After a completed
  /// model round, asks the aux-or-main model for durable user facts from
  /// the latest user + assistant pair and appends them to the memory store.
  /// Any failure is swallowed so chat never breaks.
  void recordRoundMemory(MemoryExtractor? extractor) {
    if (extractor == null) return;
    final pair = _latestRoundPair();
    if (pair == null) return;
    final conversationId = state.conversationId ?? '';
    unawaited(() async {
      try {
        final facts = await extractor.extract(
          userText: pair.userText,
          assistantText: pair.assistantText,
        );
        if (facts.isEmpty) return;
        final memoryStore = await _ref.read(memoryStoreProvider.future);
        await memoryStore?.addFacts(facts, sourceConversationId: conversationId);
      } catch (_) {
        // Auto-memory is a nice-to-have; a broken extractor or store must
        // never surface as a chat error.
      }
    }());
  }

  /// The latest user + assistant texts in the transcript, or null when
  /// either side is missing (a tool-only round has no assistant reply yet,
  /// and an image-only send has no user text).
  ({String userText, String assistantText})? _latestRoundPair() {
    String? userText;
    String? assistantText;
    for (final entry in state.entries) {
      if (entry is UserEntry && entry.text.trim().isNotEmpty) {
        userText = entry.text;
        assistantText = null;
      } else if (entry is AssistantEntry && entry.text.trim().isNotEmpty) {
        assistantText = entry.text;
      }
    }
    if (userText == null || assistantText == null) return null;
    return (userText: userText, assistantText: assistantText);
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

/// Picks the gateway that produces lightweight summaries (context
/// compaction, oversized tool digests): the auxiliary gateway when the aux
/// switch is on and the aux record is usable, otherwise the main gateway —
/// the pre-aux behavior. The aux record inherits the main model's API key
/// when it carries none of its own.
ModelGateway _summaryGateway({
  required ModelConfig mainConfig,
  required ModelConfig auxConfig,
  required bool auxEnabled,
  required ModelGateway mainGateway,
  ModelGateway? auxGateway,
}) {
  final effective = auxConfig.apiKey.isEmpty
      ? auxConfig.copyWith(apiKey: mainConfig.apiKey)
      : auxConfig;
  if (auxEnabled && effective.isComplete && auxGateway != null) {
    return auxGateway;
  }
  return mainGateway;
}

/// Builds the task's context compactor; null when the main model is not
/// configured (demo mode compacts nothing, as before). The summary digest
/// runs on the auxiliary model when it is enabled and complete.
@visibleForTesting
ContextCompactor? contextCompactorFor({
  required ModelConfig config,
  required ModelConfig auxConfig,
  required bool auxEnabled,
  required ModelGateway mainGateway,
  ModelGateway? auxGateway,
}) {
  if (!config.isComplete) return null;
  final summaryModel = _summaryGateway(
    mainConfig: config,
    auxConfig: auxConfig,
    auxEnabled: auxEnabled,
    mainGateway: mainGateway,
    auxGateway: auxGateway,
  );
  return ContextCompactor(
    windowTokens: config.effectiveContextWindow,
    summarizer: (transcript) async => (await summaryModel.complete([
          const AgentMessage(
            role: MessageRole.system,
            content: '你是会话摘要器。把以下对话记录压缩为一段简明摘要,'
                '保留:任务目标、已完成的步骤、关键文件与结论、待办事项。'
                '只输出摘要正文,不要评论。',
          ),
          AgentMessage(role: MessageRole.user, content: transcript),
        ]))
            .content,
  );
}

/// Digest closure for oversized tool results; null when the main model is
/// not configured (head+tail truncation only, as before). Same
/// auxiliary-or-main gateway choice as [contextCompactorFor].
@visibleForTesting
Future<String> Function(String)? toolDigestSummarizerFor({
  required ModelConfig config,
  required ModelConfig auxConfig,
  required bool auxEnabled,
  required ModelGateway mainGateway,
  ModelGateway? auxGateway,
}) {
  if (!config.isComplete) return null;
  final summaryModel = _summaryGateway(
    mainConfig: config,
    auxConfig: auxConfig,
    auxEnabled: auxEnabled,
    mainGateway: mainGateway,
    auxGateway: auxGateway,
  );
  return (oversized) async => (await summaryModel.complete([
        const AgentMessage(
          role: MessageRole.system,
          content: '你是工具输出摘要器。把以下超长工具输出压缩为不超过 300 字的要点,'
              '保留:关键数值、文件路径、命令结果与错误信息。只输出摘要正文。',
        ),
        AgentMessage(
          role: MessageRole.user,
          content: oversized.length > 30000
              ? oversized.substring(0, 30000)
              : oversized,
        ),
      ]))
          .content;
}

/// Builds the automatic long-term-memory extractor (PHASE 41); null when the
/// main model is not configured (demo rounds record nothing). Runs on the
/// auxiliary model when enabled, otherwise the main gateway — the same
/// choice as the context-compaction summary.
@visibleForTesting
MemoryExtractor? memoryExtractorFor({
  required ModelConfig config,
  required ModelConfig auxConfig,
  required bool auxEnabled,
  required ModelGateway mainGateway,
  ModelGateway? auxGateway,
}) {
  if (!config.isComplete) return null;
  return MemoryExtractor(
    gateway: _summaryGateway(
      mainConfig: config,
      auxConfig: auxConfig,
      auxEnabled: auxEnabled,
      mainGateway: mainGateway,
      auxGateway: auxGateway,
    ),
  );
}

/// Total budget of auto-injected facts in the system prompt (tier-aware
/// from PHASE 47): core facts always ride along — uncapped, but they
/// consume budget that recall facts would otherwise fill — and the newest
/// recall facts take whatever remains. Archival facts never auto-inject.
const int memoryPromptCap = 20;

/// 「工具使用守则」 appended to every fresh persona (PHASE 43). Kept terse —
/// it rides along on every round.
const String toolUsageRules = '「工具使用守则」\n'
    '- 优先调用工具获取事实,不要凭记忆猜测文件内容或项目结构。\n'
    '- 搜索工具(fast_find/smart_grep)返回 JSON 且已限量截断,不要重复发起全量搜索。\n'
    '- 工具失败时先检查参数(路径必须是工作区内的相对路径),再调整重试。\n'
    '- 严禁通过 run_command 绕过搜索工具执行查找/过滤类命令。\n'
    '- 需要历史对话或过往错误上下文时,调用 search_memory 检索,而不是要求用户复述。\n'
    '- 计划有变化时用 plan 工具更新,保持目标清晰。';

/// Persona prompt with the 「工具使用守则」 prepended/appended.
@visibleForTesting
String personaWithToolRules(String persona) {
  if (persona.trim().isEmpty) return toolUsageRules;
  return '$persona\n\n$toolUsageRules';
}

/// Persona prompt with the 「工具使用守则」 block prepended/appended, and
/// (from PHASE 46) the current 「当前计划」 recitation block appended after
/// the rules — still before any 「长期记忆」 block that
/// [systemPromptWithMemory] adds. Returns the persona unchanged when the
/// block is null (no plan or notes recorded yet), so bare fresh sends keep
/// their exact prefix shape.
@visibleForTesting
String personaWithRecitation(String persona, String? block) {
  if (block == null) return persona;
  if (persona.trim().isEmpty) return block;
  return '$persona\n\n$block';
}

/// Persona prompt with the 「长期记忆」 block appended (PHASE 41; tier-aware
/// from PHASE 47). Core facts always inject (uncapped), then the newest
/// recall facts fill the remaining budget up to [memoryPromptCap] total;
/// archival facts never auto-inject (search_memory covers archival
/// retrieval). Returns null when there is nothing to prepend, so bare
/// sessions and resumes keep their original message list exactly as before.
@visibleForTesting
String? systemPromptWithMemory({
  required String persona,
  required List<MemoryFact> memories,
}) {
  final core = [
    for (final fact in memories) if (fact.tier == MemoryTier.core) fact,
  ];
  final recall =
      memories.where((fact) => fact.tier == MemoryTier.recall).toList();
  final recallBudget = memoryPromptCap - core.length;
  final selectedRecall = recallBudget > 0
      ? (recall.length > recallBudget
          ? recall.sublist(recall.length - recallBudget)
          : recall)
      : const <MemoryFact>[];
  final injected = [...core, ...selectedRecall];
  if (injected.isEmpty) return persona.isEmpty ? null : persona;
  final buffer = StringBuffer();
  if (persona.isNotEmpty) {
    buffer
      ..writeln(persona)
      ..writeln();
  }
  buffer
    ..writeln('「长期记忆」以下是已保存的关于用户的长期记忆,回答时可自然运用,不必复述:')
    ..write([for (final fact in injected) '- ${fact.text}'].join('\n'));
  return buffer.toString();
}

/// Auto-approves the no-op plan/note state tools (PHASE 46): they only
/// mutate in-memory recitation state and never touch the workspace, so a
/// user prompt per update would defeat the recitation pattern. Every other
/// tool defers to the wrapped [base] policy.
class _NotesStateApprovalPolicy implements ToolApprovalPolicy {
  const _NotesStateApprovalPolicy(this._base);

  final ToolApprovalPolicy _base;

  static const _stateOnlyTools = {'plan', 'note'};

  @override
  bool requiresApproval(ToolCall call) =>
      _stateOnlyTools.contains(call.name) ? false : _base.requiresApproval(call);
}

/// Todo-recitation (PHASE 46): re-splices the current 「当前计划」 block
/// into the persona system message of every outgoing request, so `plan` and
/// `note` calls made during a task show up in the very next round — the
/// block changing across rounds is the intended recitation effect, while
/// the surrounding prompt shape stays stable. Fixed position: after the
/// tool-usage rules, before the memory block (see [spliceRecitation]).
/// [inner] (e.g. the web-search decorator) runs first.
@visibleForTesting
RequestBodyDecorator recitationBodyDecorator(
  NotesToolRegistry notes,
  RequestBodyDecorator? inner,
) {
  return (body) {
    final decorated = inner == null ? body : inner(body);
    final messages = decorated['messages'];
    if (messages is! List) return decorated;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      // The persona system message is the last message of the leading
      // system run (the Hermes recall message may precede it).
      if (message is! Map<String, dynamic> || message['role'] != 'system') {
        break;
      }
      final content = message['content'];
      if (content is String &&
          (content.contains('「工具使用守则」') ||
              content.contains('「长期记忆」') ||
              content.contains('「当前计划」'))) {
        messages[i] = {
          ...message,
          'content': spliceRecitation(content, notes.recitationBlock()),
        };
        break;
      }
    }
    return decorated;
  };
}

class _TaskRunner implements AgentTaskRunner {
  _TaskRunner({
    required ChatSessionController session,
    required SettingsStore store,
    required WorkspaceManager workspaceManager,
    required DshToolRegistry dshTools,
    required String conversationId,
    Future<ConversationImageStore?>? imageStoreFuture,
    Future<MemoryStore?>? memoryStoreFuture,
    Future<CrashLogStore?>? crashLogFuture,
    ModelGateway? chatGatewayOverride,
  })  : _session = session,
        _store = store,
        _workspaceManager = workspaceManager,
        _dshTools = dshTools,
        _conversationId = conversationId,
        _imageStoreFuture = imageStoreFuture,
        _memoryStoreFuture = memoryStoreFuture,
        _crashLogFuture = crashLogFuture,
        _chatGatewayOverride = chatGatewayOverride;

  final ChatSessionController _session;
  final SettingsStore _store;
  final WorkspaceManager _workspaceManager;
  final DshToolRegistry _dshTools;
  final String _conversationId;

  /// Persists attached images to disk so checkpoints keep short file paths
  /// instead of inline base64; null keeps the old inline behavior.
  final Future<ConversationImageStore?>? _imageStoreFuture;

  /// Long-term memory source for the system-prompt block and round
  /// extraction; null when prefs are unavailable, keeping memory best-effort.
  final Future<MemoryStore?>? _memoryStoreFuture;

  /// Test-only scripted gateway (see [chatGatewayOverrideProvider]); null
  /// in production.
  final ModelGateway? _chatGatewayOverride;

  /// Crash log store for the search_memory tool; null when prefs are slow
  /// or unavailable — history search degrades to conversations only.
  final Future<CrashLogStore?>? _crashLogFuture;

  CrashLogStore? _crashLog;

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
    // No-op plan/notes state tools (PHASE 46): fresh per task run, so plan
    // recitation state resets between tasks.
    final notesTools = NotesToolRegistry();
    final knowledgeStore = HermesKnowledgeStore(
      workspace: workspace,
      project: project.name,
      maxRecallEntries: memorySettings.recallEntries,
      maxRecallTokens: memorySettings.recallTokens,
    );
    final shellRunner = createProcessRunner();
    // Registered MCP servers join the tool surface; discovery is
    // best-effort so an unreachable server can never stall a task.
    final mcpServers = _store.loadMcpServers();
    // Supply-chain guard (PHASE 46): seed the approved-fingerprint table
    // so discovery can flag changed catalogs for re-approval.
    McpGuardLedger.seedApproved(_store.loadMcpToolFingerprints());
    final mcpRegistry = mcpServers.isEmpty
        ? null
        : await McpToolRegistry.connect(mcpServers).timeout(
            const Duration(seconds: 5),
            onTimeout: () => McpToolRegistry(tools: const []),
          );
    // Desktop sidecar MCP bridge (PHASE 45): stdio servers run on a LAN PC
    // and are consumed over HTTP. Best-effort discovery — an unreachable
    // bridge degrades to no bridge tools, never stalls a task.
    final bridgeConfig = _store.loadMcpBridge();
    AgentToolRegistry? bridgeRegistry;
    if (bridgeConfig.isComplete) {
      try {
        final registry = BridgeToolRegistry(
          baseUrl: bridgeConfig.baseUrl,
          token: bridgeConfig.token,
        );
        await registry.ensureLoaded().timeout(const Duration(seconds: 3));
        bridgeRegistry = registry;
      } catch (_) {
        bridgeRegistry = null;
      }
    }
    // Crash store is optional: slow or missing prefs degrade search_memory
    // to conversations only — never a gate.
    try {
      _crashLog = await (_crashLogFuture ?? Future.value(null));
    } catch (_) {
      _crashLog = null;
    }
    final registry = CompositeToolRegistry([
      workspaceTools,
      ShellToolRegistry(
        executor: ShellExecutor(runner: shellRunner),
      ),
      // Structured fd/rg search with find/grep fallback (PHASE 43).
      TerminalSearchTools(runner: shellRunner),
      // Self-diagnosis: the agent can grep its own past (PHASE 43).
      MemorySearchToolRegistry(
        loadSummaries: _store.loadConversations,
        loadCheckpoint: _store.loadCheckpoint,
        loadCrashes: _crashLog?.loadEntries,
      ),
      KnowledgeToolRegistry(store: knowledgeStore),
      // Plan/notes state (PHASE 46): record-only tools that feed the
      // todo-recitation block; core entries win over plugin name clashes.
      notesTools,
      _dshTools,
      ?mcpRegistry,
      ?bridgeRegistry,
    ]);
    final ModelGateway model = _chatGatewayOverride ??
        (config.isComplete
            ? OpenAiCompatibleGateway(
                baseUrl: config.baseUrl,
                apiKey: config.apiKey,
                model: config.model,
                tools: registry.openAiToolsJson(),
                // Web-search rewrite first, then per-round todo-recitation
                // (PHASE 46): the current 「当前计划」 block rides along on
                // every model round.
                bodyDecorator: recitationBodyDecorator(
                  notesTools,
                  webSearchBodyDecorator(
                    enabled: config.webSearchEnabled,
                    baseUrl: config.baseUrl,
                  ),
                ),
              )
            : DemoModelGateway());

    // Lightweight summary jobs (context-compaction digest, oversized
    // tool-output digests) run on the cheap auxiliary model when it is
    // enabled; the aux record reuses the main model's API key when it
    // carries none of its own.
    final auxStored = _store.loadAuxModelConfig();
    final auxConfig = auxStored.apiKey.isEmpty
        ? auxStored.copyWith(apiKey: config.apiKey)
        : auxStored;
    // Built whenever the aux record is usable — the constructor is
    // side-effect-free; the enable switch is applied by the summary
    // factories below.
    final ModelGateway? auxGateway = auxConfig.isComplete
        ? OpenAiCompatibleGateway(
            baseUrl: auxConfig.baseUrl,
            apiKey: auxConfig.apiKey,
            model: auxConfig.model,
          )
        : null;

    // Auto-compact long conversations against the model's context window;
    // the summary digest runs on the auxiliary model when enabled.
    final ContextCompactor? compactor = contextCompactorFor(
      config: config,
      auxConfig: auxStored,
      auxEnabled: _store.auxEnabled,
      mainGateway: model,
      auxGateway: auxGateway,
    );

    // Oversized tool results get a model digest of the full text on top of
    // head+tail truncation; same auxiliary-or-main gateway choice.
    final summarizer = toolDigestSummarizerFor(
      config: config,
      auxConfig: auxStored,
      auxEnabled: _store.auxEnabled,
      mainGateway: model,
      auxGateway: auxGateway,
    );

    // Automatic long-term memory (PHASE 41): completed rounds best-effort
    // extract durable user facts; demo mode records nothing.
    final memoryExtractor = memoryExtractorFor(
      config: config,
      auxConfig: auxStored,
      auxEnabled: _store.auxEnabled,
      mainGateway: model,
      auxGateway: auxGateway,
    );

    // Stored memories join the persona prompt so replies can use them.
    // Additive only: loading must never gate a send.
    var memories = const <MemoryFact>[];
    try {
      final memoryStore =
          await (_memoryStoreFuture ?? Future<MemoryStore?>.value(null));
      if (memoryStore != null) memories = memoryStore.loadFacts();
    } catch (_) {
      memories = const <MemoryFact>[];
    }

    final runtime = AgentRuntime(
      context: AgentContext(
        sessionId: _conversationId,
        workspace: workspace,
        model: model,
        tools: HardenedToolExecutor(
          registry: registry,
          summarizer: summarizer,
        ),
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
          // Plan/note state tools auto-run (PHASE 46); everything else
          // keeps the standard trust policy.
          base: _NotesStateApprovalPolicy(
            ToolPolicy.standard.toApprovalPolicy(),
          ),
        ),
      ),
      approvals: _session.broker,
      observer: _SessionObserver(_session, memoryExtractor),
    );

    // Persona prompt (plus any stored long-term memories) opens every fresh
    // task; a resume keeps its checkpoint. The 「当前计划」 recitation block
    // rides along after the tool rules (empty at task start — it refreshes
    // per round through the gateway body decorator).
    final systemPrompt = systemPromptWithMemory(
      persona: personaWithRecitation(
        personaWithToolRules(profile.systemPrompt),
        notesTools.recitationBlock(),
      ),
      memories: memories,
    );
    final effectiveMessages = resumeFrom == null && systemPrompt != null
        ? [
            AgentMessage(role: MessageRole.system, content: systemPrompt),
            ...preparedMessages,
          ]
        : preparedMessages;
    return runtime.run(effectiveMessages, cancellation, resumeFrom: resumeFrom);
  }
}

class _SessionObserver implements AgentObserver {
  _SessionObserver(this._session, this._memory);

  final ChatSessionController _session;

  /// Null in demo mode: no model, no automatic memory extraction.
  final MemoryExtractor? _memory;

  @override
  void onEvent(AgentEvent event) {
    switch (event) {
      case ModelStarted():
        break;
      case ModelDelta():
        _session.appendDelta(event.text);
      case ModelFinished():
        _session.recordTokens(event.inputTokens, event.outputTokens);
        if (event.succeeded) {
          _session.recordUsage(
            event.inputTokens,
            event.outputTokens,
            cachedTokens: event.cachedTokens,
          );
          _session.recordRoundMemory(_memory);
        }
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

/// Test-only override for the main chat model gateway (the test binding
/// blocks real sockets, so tests script full rounds by overriding this
/// provider with a fake gateway). Always null in production, where the
/// gateway is built from the stored [ModelConfig] below.
@visibleForTesting
final chatGatewayOverrideProvider = Provider<ModelGateway?>((ref) => null);

/// Automatic long-term memory (PHASE 41). Null when SharedPreferences is
/// unavailable (degraded hosts) — memory capture and prompt injection then
/// quietly turn off instead of breaking the session.
final memoryStoreProvider = FutureProvider<MemoryStore?>((ref) async {
  try {
    return MemoryStore(await SharedPreferences.getInstance());
  } catch (_) {
    return null;
  }
});

final chatSessionProvider =
    StateNotifierProvider<ChatSessionController, ChatSessionState>(
  (ref) => ChatSessionController(ref),
);
