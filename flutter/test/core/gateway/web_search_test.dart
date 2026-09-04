import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/core/gateway/providers.dart';
import 'package:shelly_hermes/core/gateway/web_search.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/settings_store.dart';

AgentMessage _msg(MessageRole role, String content) =>
    AgentMessage(role: role, content: content);

class _CapturingTransport implements ChatTransport {
  String? lastBody;

  static const _okBody =
      '{"choices":[{"message":{"role":"assistant","content":"ok"}}],'
      '"usage":{"prompt_tokens":1,"completion_tokens":1}}';

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    lastBody = request.body;
    return const ChatResponse(statusCode: 200, body: _okBody);
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    lastBody = request.body;
    return const ChatStreamResponse(statusCode: 200, chunks: Stream.empty());
  }
}

void main() {
  group('webSearchSupportFor', () {
    test('maps known provider hosts', () {
      expect(webSearchSupportFor('https://open.bigmodel.cn/api/paas/v4'),
          WebSearchSupport.pluginTool);
      expect(webSearchSupportFor('https://openrouter.ai/api/v1'),
          WebSearchSupport.modelSuffix);
      expect(webSearchSupportFor('https://api.deepseek.com/v1'),
          WebSearchSupport.none);
      expect(webSearchSupportFor('https://my-proxy.example.com/v1'),
          WebSearchSupport.none);
    });

    test('preset table agrees with host resolution', () {
      for (final preset in llmProviderPresets) {
        if (preset.defaultBaseUrl.isEmpty) continue;
        expect(webSearchSupportFor(preset.defaultBaseUrl), preset.webSearch,
            reason: '${preset.id} preset should match its own baseUrl');
      }
    });
  });

  group('webSearchBodyDecorator', () {
    test('null when disabled or unsupported', () {
      expect(
          webSearchBodyDecorator(
              enabled: true, baseUrl: 'https://api.deepseek.com/v1'),
          isNull);
      expect(
          webSearchBodyDecorator(
              enabled: false, baseUrl: 'https://openrouter.ai/api/v1'),
          isNull);
    });

    test('pluginTool injects web_search plugin alongside function tools',
        () {
      final decorate = webSearchBodyDecorator(
        enabled: true,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      )!;
      final body = {
        'model': 'glm-4.6',
        'tools': [
          {'type': 'function', 'function': {'name': 'read_file'}},
        ],
      };
      final decorated = decorate(body);
      final tools = decorated['tools'] as List;
      expect(tools, hasLength(2));
      expect(tools.last, {
        'type': 'web_search',
        'web_search': {'enable': true},
      });
    });

    test('pluginTool works when no tools are present', () {
      final decorate = webSearchBodyDecorator(
        enabled: true,
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      )!;
      final decorated = decorate({'model': 'glm-4.6'});
      expect(decorated['tools'], hasLength(1));
    });

    test('modelSuffix appends :online once', () {
      final decorate = webSearchBodyDecorator(
        enabled: true,
        baseUrl: 'https://openrouter.ai/api/v1',
      )!;
      expect(decorate({'model': 'google/gemini-2.0-flash'})['model'],
          'google/gemini-2.0-flash:online');
      expect(decorate({'model': 'google/gemini-2.0-flash:online'})['model'],
          'google/gemini-2.0-flash:online');
    });
  });

  group('gateway bodyDecorator', () {
    test('decorated body reaches the wire', () async {
      final transport = _CapturingTransport();
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'k',
        model: 'google/gemini-2.0-flash',
        transport: transport,
        bodyDecorator: webSearchBodyDecorator(
          enabled: true,
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
      );

      await gateway.complete([_msg(MessageRole.user, 'hi')]);
      final body =
          jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(body['model'], 'google/gemini-2.0-flash:online');
    });

    test('no decorator leaves the body untouched', () async {
      final transport = _CapturingTransport();
      final gateway = OpenAiCompatibleGateway(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'k',
        model: 'deepseek-chat',
        transport: transport,
      );

      await gateway.complete([_msg(MessageRole.user, 'hi')]);
      final body =
          jsonDecode(transport.lastBody!) as Map<String, dynamic>;
      expect(body['model'], 'deepseek-chat');
      expect(body.containsKey('tools'), isFalse);
    });
  });

  group('ModelConfig.webSearchEnabled persistence', () {
    test('round-trips through the settings store', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      await store.saveModelConfig(const ModelConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'k',
        model: 'glm-4.6',
        webSearchEnabled: true,
      ));
      expect(store.loadModelConfig().webSearchEnabled, isTrue);

      await store.saveModelConfig(
          store.loadModelConfig().copyWith(webSearchEnabled: false));
      expect(store.loadModelConfig().webSearchEnabled, isFalse);
    });
  });
}
