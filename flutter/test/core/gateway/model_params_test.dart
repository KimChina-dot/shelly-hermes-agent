import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Captures request bodies so the test can assert exactly which sampling
/// fields reached the wire (same scripted-transport pattern as the
/// cache_metrics / web_search gateway tests).
class _CapturingTransport implements ChatTransport {
  _CapturingTransport();

  ChatRequest? lastRequest;

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    lastRequest = request;
    return const ChatResponse(
      statusCode: 200,
      body: '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}',
    );
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    lastRequest = request;
    const sse = 'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
        'data: [DONE]\n\n';
    return ChatStreamResponse(statusCode: 200, chunks: Stream.value(sse));
  }
}

OpenAiCompatibleGateway _gateway(
  _CapturingTransport transport, {
  double? temperature,
  double? topP,
  int? maxTokens,
}) =>
    OpenAiCompatibleGateway(
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'k',
      model: 'test-model',
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      transport: transport,
    );

Map<String, dynamic> _wireBody(_CapturingTransport transport) =>
    jsonDecode(transport.lastRequest!.body) as Map<String, dynamic>;

void main() {
  group('request payload carries sampling params only when set', () {
    test('all params unset: fields omitted from the JSON body', () async {
      final transport = _CapturingTransport();
      await _gateway(transport).complete(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
      );

      final body = _wireBody(transport);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('temperature set: only temperature reaches the wire', () async {
      final transport = _CapturingTransport();
      await _gateway(transport, temperature: 0.7).complete(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
      );

      final body = _wireBody(transport);
      expect(body['temperature'], 0.7);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('top_p set: only top_p reaches the wire', () async {
      final transport = _CapturingTransport();
      await _gateway(transport, topP: 0.95).complete(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
      );

      final body = _wireBody(transport);
      expect(body['top_p'], 0.95);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('maxTokens set: only max_tokens reaches the wire', () async {
      final transport = _CapturingTransport();
      await _gateway(transport, maxTokens: 4096).complete(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
      );

      final body = _wireBody(transport);
      expect(body['max_tokens'], 4096);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('all params set: all three reach the wire', () async {
      final transport = _CapturingTransport();
      await _gateway(
        transport,
        temperature: 0.3,
        topP: 0.5,
        maxTokens: 512,
      ).complete([AgentMessage(role: MessageRole.user, content: 'hi')]);

      final body = _wireBody(transport);
      expect(body['temperature'], 0.3);
      expect(body['top_p'], 0.5);
      expect(body['max_tokens'], 512);
    });

    test('streaming path includes the params when set', () async {
      final transport = _CapturingTransport();
      await _gateway(
        transport,
        temperature: 1.5,
        topP: 0.9,
        maxTokens: 2048,
      ).completeStreaming(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
        (_) {},
      );

      final body = _wireBody(transport);
      expect(body['stream'], true);
      expect(body['temperature'], 1.5);
      expect(body['top_p'], 0.9);
      expect(body['max_tokens'], 2048);
    });

    test('streaming path omits the params when unset', () async {
      final transport = _CapturingTransport();
      await _gateway(transport).completeStreaming(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
        (_) {},
      );

      final body = _wireBody(transport);
      expect(body['stream'], true);
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
    });
  });

  group('ModelConfig sampling params', () {
    test('defaults are unset', () {
      const config = ModelConfig();
      expect(config.temperature, isNull);
      expect(config.topP, isNull);
      expect(config.maxTokens, isNull);
    });

    test('JSON round-trip preserves set params', () {
      const config = ModelConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        model: 'test-model',
        temperature: 0.7,
        topP: 0.95,
        maxTokens: 4096,
      );

      final restored = ModelConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );

      expect(restored.baseUrl, config.baseUrl);
      expect(restored.model, config.model);
      expect(restored.temperature, 0.7);
      expect(restored.topP, 0.95);
      expect(restored.maxTokens, 4096);
      expect(restored.isComplete, isTrue);
    });

    test('JSON omits unset params and they stay null after decode', () {
      const config = ModelConfig(baseUrl: 'b', apiKey: 'k', model: 'm');

      final json = config.toJson();
      expect(json.containsKey('temperature'), isFalse);
      expect(json.containsKey('topP'), isFalse);
      expect(json.containsKey('maxTokens'), isFalse);

      final restored = ModelConfig.fromJson(json);
      expect(restored.temperature, isNull);
      expect(restored.topP, isNull);
      expect(restored.maxTokens, isNull);
    });

    test('legacy JSON without the fields decodes to unset params', () {
      final restored = ModelConfig.fromJson({
        'baseUrl': 'b',
        'apiKey': 'k',
        'model': 'm',
      });
      expect(restored.temperature, isNull);
      expect(restored.topP, isNull);
      expect(restored.maxTokens, isNull);
    });

    test('copyWith overrides params; null keeps existing values', () {
      const config = ModelConfig(
        temperature: 0.7,
        topP: 0.95,
        maxTokens: 4096,
      );

      final changed = config.copyWith(temperature: 1.2, topP: 0.5);
      expect(changed.temperature, 1.2);
      expect(changed.topP, 0.5);
      expect(changed.maxTokens, 4096);

      final untouched = config.copyWith(baseUrl: 'b');
      expect(untouched.temperature, 0.7);
      expect(untouched.topP, 0.95);
      expect(untouched.maxTokens, 4096);
    });
  });

  group('configured ModelConfig params reach the gateway wire', () {
    test('config sampling params flow into the request body', () async {
      const config = ModelConfig(
        baseUrl: 'https://example.invalid/v1',
        apiKey: 'k',
        model: 'test-model',
        temperature: 0.6,
        topP: 0.85,
        maxTokens: 1024,
      );
      final transport = _CapturingTransport();
      final gateway = OpenAiCompatibleGateway(
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        model: config.model,
        temperature: config.temperature,
        topP: config.topP,
        maxTokens: config.maxTokens,
        transport: transport,
      );

      await gateway.complete(
        [AgentMessage(role: MessageRole.user, content: 'hi')],
      );

      final body = _wireBody(transport);
      expect(body['model'], config.model);
      expect(body['temperature'], 0.6);
      expect(body['top_p'], 0.85);
      expect(body['max_tokens'], 1024);
    });
  });
}
