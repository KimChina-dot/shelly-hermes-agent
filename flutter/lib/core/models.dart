import 'dart:convert';

/// Core data model of the Hermes agent engine, ported 1:1 from the Kotlin
/// `core` module (`AgentModels.kt`) so semantics stay identical.
enum MessageRole { system, user, assistant, tool }

/// A text-like file the user attached to a message (source code, markdown,
/// CSV, …). The content rides along in checkpoints but is only spliced into
/// the model request at wire-encoding time — the transcript shows the file
/// name, not the raw body.
class TextFileAttachment {
  const TextFileAttachment({required this.name, required this.content});

  final String name;
  final String content;

  Map<String, dynamic> toJson() => {'name': name, 'content': content};

  static TextFileAttachment fromJson(Map<String, dynamic> json) =>
      TextFileAttachment(
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is TextFileAttachment &&
      other.name == name &&
      other.content == content;

  @override
  int get hashCode => Object.hash(name, content);
}

/// Splices text attachments into the message body sent to the model.
String composeMessageContent(String text, List<TextFileAttachment> files) {
  if (files.isEmpty) return text;
  final buffer = StringBuffer(text.trim());
  for (final file in files) {
    buffer
      ..writeln()
      ..writeln()
      ..writeln('--- 附件:${file.name} ---')
      ..writeln(file.content);
  }
  return buffer.toString();
}

class AgentMessage {
  const AgentMessage({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolCalls = const [],
    this.images = const [],
    this.textFiles = const [],
  });

  final MessageRole role;
  final String content;
  final String? toolCallId;
  final List<ToolCall> toolCalls;

  /// Attached images as `data:` URLs (vision-capable models only); empty for
  /// plain-text messages. Only meaningful on user messages today.
  final List<String> images;

  /// Attached text-like files; spliced into the wire content for user
  /// messages, shown as name chips in the transcript.
  final List<TextFileAttachment> textFiles;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (toolCalls.isNotEmpty)
          'toolCalls': toolCalls.map((c) => c.toJson()).toList(),
        if (images.isNotEmpty) 'images': images,
        if (textFiles.isNotEmpty)
          'textFiles': textFiles.map((f) => f.toJson()).toList(),
      };

  static AgentMessage fromJson(Map<String, dynamic> json) => AgentMessage(
        role: MessageRole.values.byName(json['role'] as String),
        content: json['content'] as String,
        toolCallId: json['toolCallId'] as String?,
        toolCalls: (json['toolCalls'] as List<dynamic>? ?? const [])
            .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
            .toList(),
        images: (json['images'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        textFiles: (json['textFiles'] as List<dynamic>? ?? const [])
            .map((e) => TextFileAttachment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is AgentMessage &&
      other.role == role &&
      other.content == content &&
      other.toolCallId == toolCallId &&
      _listEquals(other.toolCalls, toolCalls) &&
      _listEquals(other.images, images) &&
      _listEquals(other.textFiles, textFiles);

  @override
  int get hashCode => Object.hash(
        role,
        content,
        toolCallId,
        Object.hashAll(toolCalls),
        Object.hashAll(images),
        Object.hashAll(textFiles),
      );

  @override
  String toString() =>
      'AgentMessage(${role.name}, $content${toolCalls.isEmpty ? '' : ', toolCalls: ${toolCalls.length}'})';
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.argumentsJson});

  final String id;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'argumentsJson': argumentsJson};

  static ToolCall fromJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String,
        name: json['name'] as String,
        argumentsJson: json['argumentsJson'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is ToolCall &&
      other.id == id &&
      other.name == name &&
      other.argumentsJson == argumentsJson;

  @override
  int get hashCode => Object.hash(id, name, argumentsJson);

  @override
  String toString() => 'ToolCall($id, $name)';
}

class ModelReply {
  const ModelReply({
    this.content = '',
    this.toolCalls = const [],
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final String content;
  final List<ToolCall> toolCalls;
  final int inputTokens;
  final int outputTokens;
}

class AgentLimits {
  const AgentLimits({
    this.maxRounds = 16,
    this.maxTokens = 64000,
    this.maxToolCalls = 32,
  });

  final int maxRounds;
  final int maxTokens;
  final int maxToolCalls;
}

/// Durable execution queue used to restore a task after the OS kills the app.
class PendingToolCall {
  const PendingToolCall({required this.call, required this.stage});

  final ToolCall call;
  final ToolExecutionStage stage;

  Map<String, dynamic> toJson() =>
      {'call': call.toJson(), 'stage': stage.name};

  static PendingToolCall fromJson(Map<String, dynamic> json) => PendingToolCall(
        call: ToolCall.fromJson(json['call'] as Map<String, dynamic>),
        stage: ToolExecutionStage.values.byName(json['stage'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is PendingToolCall &&
      other.call == call &&
      other.stage == stage;

  @override
  int get hashCode => Object.hash(call, stage);
}

enum ToolExecutionStage { awaitingApproval, awaitingExecution, running }

class AgentCheckpoint {
  const AgentCheckpoint({
    required this.messages,
    required this.round,
    required this.consumedTokens,
    required this.toolCalls,
    this.pendingToolCalls = const [],
  });

  final List<AgentMessage> messages;
  final int round;
  final int consumedTokens;
  final int toolCalls;
  final List<PendingToolCall> pendingToolCalls;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'messages': messages.map((m) => m.toJson()).toList(),
        'round': round,
        'consumedTokens': consumedTokens,
        'toolCalls': toolCalls,
        'pendingToolCalls':
            pendingToolCalls.map((p) => p.toJson()).toList(),
      };

  static AgentCheckpoint fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 1;
    if (version != 1) {
      throw FormatException('Unsupported checkpoint version: $version');
    }
    return AgentCheckpoint(
      messages: (json['messages'] as List<dynamic>)
          .map((e) => AgentMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      round: json['round'] as int,
      consumedTokens: json['consumedTokens'] as int,
      toolCalls: json['toolCalls'] as int,
      pendingToolCalls: (json['pendingToolCalls'] as List<dynamic>? ?? const [])
          .map((e) => PendingToolCall.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  String encode() => jsonEncode(toJson());

  static AgentCheckpoint decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      other is AgentCheckpoint &&
      other.round == round &&
      other.consumedTokens == consumedTokens &&
      other.toolCalls == toolCalls &&
      _listEquals(other.messages, messages) &&
      _listEquals(other.pendingToolCalls, pendingToolCalls);

  @override
  int get hashCode => Object.hash(round, consumedTokens, toolCalls);
}

/// Lightweight lifecycle signals for progress UI, metrics and diagnostics.
sealed class AgentEvent {
  const AgentEvent();
}

class ModelStarted extends AgentEvent {
  const ModelStarted(this.round);
  final int round;
}

class ModelDelta extends AgentEvent {
  const ModelDelta(this.text);
  final String text;
}

class ModelFinished extends AgentEvent {
  const ModelFinished({
    required this.round,
    required this.durationMillis,
    required this.succeeded,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final int round;
  final int durationMillis;
  final bool succeeded;
  final int inputTokens;
  final int outputTokens;
}

class ApprovalWaiting extends AgentEvent {
  const ApprovalWaiting(this.call);
  final ToolCall call;
}

class ApprovalFinished extends AgentEvent {
  const ApprovalFinished({
    required this.call,
    required this.durationMillis,
    required this.decision,
  });

  final ToolCall call;
  final int durationMillis;

  /// Null when the wait ended abnormally (the gateway threw).
  final ApprovalDecision? decision;
}

class ToolStarted extends AgentEvent {
  const ToolStarted(this.toolCallId, this.toolName, [this.argumentsJson = '']);
  final String toolCallId;
  final String toolName;
  final String argumentsJson;
}

/// Emitted when the context compactor folded older messages so the next
/// model round fits the model's context window.
class ContextCompacted extends AgentEvent {
  const ContextCompacted({
    required this.droppedMessages,
    required this.tokensBefore,
    required this.tokensAfter,
    required this.usedModelSummary,
  });

  final int droppedMessages;
  final int tokensBefore;
  final int tokensAfter;

  /// False when the model-based summarizer failed and a heuristic
  /// placeholder was used instead.
  final bool usedModelSummary;
}

class ToolFinished extends AgentEvent {
  const ToolFinished({
    required this.toolCallId,
    required this.toolName,
    required this.durationMillis,
    required this.succeeded,
    this.result,
  });

  final String toolCallId;
  final String toolName;
  final int durationMillis;
  final bool succeeded;
  final String? result;
}

enum ApprovalDecision { approve, reject }

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
