import 'dart:async';
import 'dart:convert';

// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals

import 'package:http/http.dart' as http;

import '../agent_core.dart';
import '../models.dart';
import 'openai_messages.dart';
import 'sse.dart';

/// Pluggable HTTP transport so the gateway can be tested without sockets.
/// Default implementation speaks real HTTP via package:http.
abstract interface class ChatTransport {
  /// POSTs [request] and returns the full response (non-streaming path).
  Future<ChatResponse> post(ChatRequest request);

  /// POSTs [request] and returns the decoded text stream (SSE path; the
  /// raw body when the response is an error page).
  Future<ChatStreamResponse> postStreaming(ChatRequest request);
}

class ChatRequest {
  const ChatRequest({
    required this.url,
    required this.headers,
    required this.body,
    this.timeout = const Duration(seconds: 120),
  });

  final String url;
  final Map<String, String> headers;
  final String body;
  final Duration timeout;
}

class ChatResponse {
  const ChatResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
}

class ChatStreamResponse {
  const ChatStreamResponse({required this.statusCode, required this.chunks});

  final int statusCode;
  final Stream<String> chunks;

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
}

class HttpChatTransport implements ChatTransport {
  HttpChatTransport({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    final response = await _client
        .post(
          Uri.parse(request.url),
          headers: request.headers,
          body: request.body,
        )
        .timeout(request.timeout);
    return ChatResponse(statusCode: response.statusCode, body: response.body);
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    final httpRequest = http.Request('POST', Uri.parse(request.url))
      ..headers.addAll(request.headers)
      ..body = request.body;
    final response = await _client.send(httpRequest).timeout(request.timeout);
    return ChatStreamResponse(
      statusCode: response.statusCode,
      chunks: response.stream.transform(const Utf8Decoder(allowMalformed: true)),
    );
  }
}

class GatewayException implements Exception {
  GatewayException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() =>
      'GatewayException($message${statusCode == null ? '' : ', status: $statusCode'})';
}

/// [ModelReply] with KV-cache telemetry attached (PHASE 46). The gateway
/// always returns this subclass, so every round carries the OpenAI-compatible
/// `usage.prompt_tokens_details.cached_tokens` figure; providers that omit
/// the field leave [promptCachedTokens] at 0 and any consumer that expects a
/// plain [ModelReply] keeps working unchanged.
class CachedTokensReply extends ModelReply {
  const CachedTokensReply({
    super.content = '',
    super.toolCalls = const [],
    super.inputTokens = 0,
    super.outputTokens = 0,
    this.promptCachedTokens = 0,
  });

  /// Prompt tokens served from the provider's KV cache this round.
  final int promptCachedTokens;
}

/// Reads the cache-hit figure from a chat/completions `usage` object.
/// Returns null when the provider reports none: the canonical OpenAI field
/// is `prompt_tokens_details.cached_tokens`, with DeepSeek-style
/// `prompt_cache_hit_tokens` accepted as a fallback. The result is clamped
/// to `prompt_tokens` so a malformed payload can never push the cache-hit
/// rate above 100%.
int? cachedTokensFromUsage(Map<String, dynamic>? usage) {
  if (usage == null) return null;
  int? cached;
  final details = usage['prompt_tokens_details'];
  if (details is Map<String, dynamic>) {
    final value = details['cached_tokens'];
    if (value is num) cached = value.toInt();
  }
  if (cached == null) {
    final legacy = usage['prompt_cache_hit_tokens'];
    if (legacy is num) cached = legacy.toInt();
  }
  if (cached == null) return null;
  final prompt = (usage['prompt_tokens'] as num?)?.toInt();
  if (prompt != null && cached > prompt) return prompt;
  return cached;
}

/// OpenAI-compatible chat/completions gateway: works with any endpoint that
/// speaks the standard schema (OpenAI, DeepSeek, Qwen compatible mode,
/// OpenRouter, local vLLM...). Supports tool calls, SSE streaming with delta
/// accumulation, per-request timeout, and bounded retry on 429/5xx for the
/// non-streaming path.
class OpenAiCompatibleGateway implements StreamingModelGateway {
  OpenAiCompatibleGateway({
    required String baseUrl,
    required String apiKey,
    required String model,
    this.tools,
    this.temperature,
    this.topP,
    this.maxTokens,
    ChatTransport? transport,
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 600),
    Map<String, String> extraHeaders = const {},
    this.bodyDecorator,
  })  : _endpoint =
            '${baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl}/chat/completions',
        _headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
          ...extraHeaders,
        },
        _model = model,
        _transport = transport ?? HttpChatTransport();

  final String _endpoint;
  final Map<String, String> _headers;
  final String _model;
  final ChatTransport _transport;
  final int maxRetries;
  final Duration retryDelay;
  final double? temperature;

  /// nucleus-sampling cutoff (`top_p` on the wire); null leaves the field
  /// out of the request body so the provider default applies.
  final double? topP;
  final int? maxTokens;

  /// OpenAI function-calling definitions advertised to the model; taken
  /// from the tool registry's [WorkspaceToolRegistry.openAiToolsJson].
  final List<Map<String, dynamic>>? tools;

  /// Last-chance rewrite of the JSON body before it is encoded and sent
  /// (e.g. provider web-search plugin injection); null leaves it untouched.
  final Map<String, dynamic> Function(Map<String, dynamic> body)?
      bodyDecorator;

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    final request = _buildRequest(messages, stream: false);
    var attempt = 0;
    while (true) {
      final response = await _transport.post(request);
      if (response.isSuccessful) return _decodePayload(response.body);
      if (!_isRetryableStatus(response.statusCode) || attempt >= maxRetries) {
        throw GatewayException(
          'chat/completions failed',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
      attempt += 1;
      await Future<void>.delayed(retryDelay * attempt);
    }
  }

  @override
  Future<ModelReply> completeStreaming(
    List<AgentMessage> messages,
    void Function(String text) onDelta,
  ) async {
    final request = _buildRequest(messages, stream: true);
    final response = await _transport.postStreaming(request);
    if (!response.isSuccessful) {
      throw GatewayException(
        'chat/completions failed',
        statusCode: response.statusCode,
        body: await _drain(response.chunks),
      );
    }

    final parser = SseParser();
    final accumulator = ToolCallAccumulator();
    final content = StringBuffer();
    var inputTokens = 0;
    var outputTokens = 0;
    var cachedTokens = 0;
    final done = Completer<void>();

    parser.data.listen(
      (payload) {
        if (payload == '[DONE]') {
          if (!done.isCompleted) done.complete();
          return;
        }
        try {
          final payloadJson = jsonDecode(payload) as Map<String, dynamic>;
          final choices = payloadJson['choices'] as List<dynamic>? ?? const [];
          if (choices.isNotEmpty) {
            final choice = choices.first as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>? ?? const {};
            final text = delta['content'] as String?;
            if (text != null && text.isNotEmpty) {
              content.write(text);
              onDelta(text);
            }
            accumulator.addFragments(delta['tool_calls'] as List<dynamic>?);
          }
          final usage = payloadJson['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            inputTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? inputTokens;
            outputTokens =
                (usage['completion_tokens'] as num?)?.toInt() ?? outputTokens;
            cachedTokens = cachedTokensFromUsage(usage) ?? cachedTokens;
          }
        } on FormatException {
          // Ignore malformed keep-alive fragments; the stream continues.
        }
      },
      onError: done.completeError,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    response.chunks.listen(
      parser.addChunk,
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
      onDone: () => parser.close(),
      cancelOnError: true,
    );

    await done.future;
    return CachedTokensReply(
      content: content.toString(),
      toolCalls: accumulator.build(),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      promptCachedTokens: cachedTokens,
    );
  }

  ChatRequest _buildRequest(List<AgentMessage> messages, {required bool stream}) {
    final body = <String, dynamic>{
      'model': _model,
      'messages': encodeMessages(messages),
      'stream': stream,
      if (tools != null && tools!.isNotEmpty) 'tools': tools,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (maxTokens != null) 'max_tokens': maxTokens,
    };
    final payload = bodyDecorator?.call(body) ?? body;
    return ChatRequest(url: _endpoint, headers: _headers, body: jsonEncode(payload));
  }

  ModelReply _decodePayload(String body) {
    late final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw GatewayException('malformed JSON from gateway', body: body);
    }
    final reply = decodeMessagePayload(payload);
    return CachedTokensReply(
      content: reply.content,
      toolCalls: reply.toolCalls,
      inputTokens: reply.inputTokens,
      outputTokens: reply.outputTokens,
      promptCachedTokens: cachedTokensFromUsage(payload['usage'] as Map<String, dynamic>?) ?? 0,
    );
  }

  bool _isRetryableStatus(int statusCode) =>
      statusCode == 429 || statusCode >= 500;
}

Future<String> _drain(Stream<String> chunks) async {
  final buffer = StringBuffer();
  try {
    await for (final chunk in chunks) {
      buffer.write(chunk);
    }
  } catch (_) {}
  return buffer.toString();
}
