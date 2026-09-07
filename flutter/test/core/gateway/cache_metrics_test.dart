import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/models.dart';

/// Scripts the gateway HTTP layer with canned payloads so cache telemetry
/// can be asserted without sockets.
class _ScriptedTransport implements ChatTransport {
  _ScriptedTransport(this.responseBody);

  final String responseBody;

  @override
  Future<ChatResponse> post(ChatRequest request) async =>
      ChatResponse(statusCode: 200, body: responseBody);

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async =>
      ChatStreamResponse(
        statusCode: 200,
        chunks: Stream.value(responseBody),
      );
}

const _content =
    '{"choices":[{"message":{"role":"assistant","content":"ok"}}],';

OpenAiCompatibleGateway _gateway(String body) => OpenAiCompatibleGateway(
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      model: 'test-model',
      transport: _ScriptedTransport(body),
    );

/// The gateway interface returns [ModelReply]; production replies are
/// [CachedTokensReply] instances carrying the cache figure.
Future<CachedTokensReply> _complete(OpenAiCompatibleGateway gateway) async =>
    await gateway.complete(
            [AgentMessage(role: MessageRole.user, content: 'hi')])
        as CachedTokensReply;

void main() {
  group('cachedTokensFromUsage payload mapping', () {
    test('reads prompt_tokens_details.cached_tokens', () {
      final usage = {
        'prompt_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 64},
      };
      expect(cachedTokensFromUsage(usage), 64);
    });

    test('returns null when the provider omits the field', () {
      expect(cachedTokensFromUsage(null), isNull);
      expect(cachedTokensFromUsage({'prompt_tokens': 100}), isNull);
      expect(
        cachedTokensFromUsage({
          'prompt_tokens': 100,
          'prompt_tokens_details': 'garbage',
        }),
        isNull,
      );
    });

    test('falls back to prompt_cache_hit_tokens', () {
      expect(
        cachedTokensFromUsage({
          'prompt_tokens': 100,
          'prompt_cache_hit_tokens': 32,
        }),
        32,
      );
    });

    test('clamps malformed cached_tokens above prompt_tokens', () {
      expect(
        cachedTokensFromUsage({
          'prompt_tokens': 10,
          'prompt_tokens_details': {'cached_tokens': 999},
        }),
        10,
      );
    });

    test('zero prompt tokens stay zero-division-safe', () {
      expect(
        cachedTokensFromUsage({
          'prompt_tokens': 0,
          'prompt_tokens_details': {'cached_tokens': 0},
        }),
        0,
      );
    });
  });

  group('CachedTokensReply (non-streaming)', () {
    test('round carries cached_tokens when present', () async {
      final body =
          '$_content"usage":{"prompt_tokens":100,"completion_tokens":20,'
          '"prompt_tokens_details":{"cached_tokens":64}}'
          '}';
      final reply = await _complete(_gateway(body));

      expect(reply.inputTokens, 100);
      expect(reply.outputTokens, 20);
      expect(reply.promptCachedTokens, 64);
    });

    test('defaults promptCachedTokens to 0 when the field is absent',
        () async {
      final body =
          '$_content"usage":{"prompt_tokens":100,"completion_tokens":20}}';
      final reply = await _complete(_gateway(body));

      expect(reply.promptCachedTokens, 0);
      // Backward compatible: the reply still is a ModelReply.
      expect(reply, isA<ModelReply>());
    });

    test('promptCachedTokens is 0 when usage itself is missing', () async {
      final body =
          '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}';
      final reply = await _complete(_gateway(body));

      expect(reply.inputTokens, 0);
      expect(reply.outputTokens, 0);
      expect(reply.promptCachedTokens, 0);
    });

    test('accepts the DeepSeek-style prompt_cache_hit_tokens fallback',
        () async {
      final body =
          '$_content"usage":{"prompt_tokens":100,"completion_tokens":20,'
          '"prompt_cache_hit_tokens":32}}';
      final reply = await _complete(_gateway(body));

      expect(reply.promptCachedTokens, 32);
    });
  });

  group('CachedTokensReply (streaming)', () {
    test('reads cached_tokens from the streamed usage chunk', () async {
      final usageChunk = jsonEncode({
        'choices': [],
        'usage': {
          'prompt_tokens': 200,
          'completion_tokens': 30,
          'prompt_tokens_details': {'cached_tokens': 160},
        },
      });
      final sse = 'data: $usageChunk\n\n'
          'data: [DONE]\n\n';
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        model: 'test-model',
        transport: _ScriptedTransport(sse),
      );

      final deltas = <String>[];
      final reply = await gateway.completeStreaming(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
        deltas.add,
      ) as CachedTokensReply;

      expect(reply.inputTokens, 200);
      expect(reply.outputTokens, 30);
      expect(reply.promptCachedTokens, 160);
      expect(deltas, isEmpty);
    });

    test('stream without usage yields 0 cached tokens', () async {
      final usageChunk = jsonEncode({
        'choices': [
          {
            'delta': {'content': 'hey'},
          },
        ],
      });
      final sse = 'data: $usageChunk\n\ndata: [DONE]\n\n';
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        model: 'test-model',
        transport: _ScriptedTransport(sse),
      );

      final reply = await gateway.completeStreaming(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
        (_) {},
      ) as CachedTokensReply;

      expect(reply.content, 'hey');
      expect(reply.promptCachedTokens, 0);
    });
  });
}
