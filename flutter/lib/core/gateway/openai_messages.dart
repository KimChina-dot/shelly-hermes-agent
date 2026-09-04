import '../../platform/conversation_images.dart';
import '../models.dart';

/// Wire-format mapping between the Hermes [AgentMessage] model and the
/// OpenAI-compatible chat/completions schema.

Map<String, dynamic> _encodeUser(AgentMessage message) {
  // Attached text files are spliced into the text part; the transcript-only
  // message.content stays clean for memory, compaction and display.
  final text = composeMessageContent(message.content, message.textFiles);
  if (message.images.isEmpty) return {'role': 'user', 'content': text};
  final parts = <Map<String, dynamic>>[
    if (text.isNotEmpty) {'type': 'text', 'text': text},
    // File-path references (on-disk image cache) expand to data URLs here;
    // unreadable files drop their image part instead of failing the request.
    for (final reference in message.images)
      if (imageWireUrl(reference) case final String url)
        {
          'type': 'image_url',
          'image_url': {'url': url},
        },
  ];
  return {'role': 'user', 'content': parts};
}

List<Map<String, dynamic>> encodeMessages(List<AgentMessage> messages) {
  return [
    for (final message in messages)
      switch (message.role) {
        MessageRole.system => {'role': 'system', 'content': message.content},
        MessageRole.user => _encodeUser(message),
        MessageRole.assistant => {
            'role': 'assistant',
            if (message.content.isNotEmpty) 'content': message.content,
            if (message.toolCalls.isNotEmpty)
              'tool_calls': [
                for (final call in message.toolCalls)
                  {
                    'id': call.id,
                    'type': 'function',
                    'function': {
                      'name': call.name,
                      'arguments': call.argumentsJson,
                    },
                  },
              ],
          },
        MessageRole.tool => {
            'role': 'tool',
            'tool_call_id': message.toolCallId,
            'content': message.content,
          },
      },
  ];
}

/// Decodes a non-streaming choice payload (`choices[0].message`).
ModelReply decodeMessagePayload(Map<String, dynamic> payload) {
  final choices = payload['choices'] as List<dynamic>? ?? const [];
  if (choices.isEmpty) {
    return const ModelReply();
  }
  final choice = choices.first as Map<String, dynamic>;
  final message = choice['message'] as Map<String, dynamic>? ?? const {};
  final usage = payload['usage'] as Map<String, dynamic>?;
  return ModelReply(
    content: message['content'] as String? ?? '',
    toolCalls: decodeToolCalls(message['tool_calls'] as List<dynamic>?),
    inputTokens: _usageField(usage, const ['prompt_tokens', 'input_tokens']),
    outputTokens: _usageField(usage, const ['completion_tokens', 'output_tokens']),
  );
}

/// Decodes accumulated OpenAI tool_call entries into [ToolCall]s.
List<ToolCall> decodeToolCalls(List<dynamic>? rawCalls) {
  if (rawCalls == null) return const [];
  return [
    for (final raw in rawCalls)
      if (raw is Map<String, dynamic>)
        ToolCall(
          id: raw['id'] as String? ?? '',
          name: (raw['function'] as Map<String, dynamic>?)?['name'] as String? ?? '',
          argumentsJson:
              (raw['function'] as Map<String, dynamic>?)?['arguments'] as String? ?? '',
        ),
  ];
}

/// Accumulates streamed `delta.tool_calls` fragments keyed by their index,
/// producing complete tool calls once the stream ends.
class ToolCallAccumulator {
  final Map<int, _PendingCall> _pending = {};

  void addFragments(List<dynamic>? fragments) {
    if (fragments == null) return;
    for (final raw in fragments) {
      if (raw is! Map<String, dynamic>) continue;
      final index = (raw['index'] as num?)?.toInt() ?? 0;
      final function = raw['function'] as Map<String, dynamic>?;
      final pending = _pending.putIfAbsent(index, () => _PendingCall());
      final id = raw['id'] as String?;
      if (id != null) pending.id = id;
      if (function != null) {
        final name = function['name'] as String?;
        if (name != null) pending.name = name;
        final arguments = function['arguments'] as String?;
        if (arguments != null) pending.arguments.write(arguments);
      }
    }
  }

  List<ToolCall> build() {
    final indices = _pending.keys.toList()..sort();
    return [
      for (final index in indices)
        ToolCall(
          id: _pending[index]!.id,
          name: _pending[index]!.name,
          argumentsJson: _pending[index]!.arguments.toString(),
        ),
    ];
  }
}

int _usageField(Map<String, dynamic>? usage, List<String> keys) {
  if (usage == null) return 0;
  for (final key in keys) {
    final value = usage[key];
    if (value is num) return value.toInt();
  }
  return 0;
}

class _PendingCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
