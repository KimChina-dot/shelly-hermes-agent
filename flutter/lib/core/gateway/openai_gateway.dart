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
    this.temperature,
    this.maxTokens,
    ChatTransport? transport,
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 600),
    Map<String, String> extraHeaders = const {},
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
  final int? maxTokens;

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
    return ModelReply(
      content: content.toString(),
      toolCalls: accumulator.build(),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  }

  ChatRequest _buildRequest(List<AgentMessage> messages, {required bool stream}) {
    final body = <String, dynamic>{
      'model': _model,
      'messages': encodeMessages(messages),
      'stream': stream,
      if (temperature != null) 'temperature': temperature,
      if (maxTokens != null) 'max_tokens': maxTokens,
    };
    return ChatRequest(url: _endpoint, headers: _headers, body: jsonEncode(body));
  }

  ModelReply _decodePayload(String body) {
    late final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw GatewayException('malformed JSON from gateway', body: body);
    }
    return decodeMessagePayload(payload);
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
