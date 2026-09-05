import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/chat_session.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Gateway stub that replays canned replies and records every request, so
/// tests can tell which endpoint served a summary.
class _ScriptedGateway implements ModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seenMessages = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seenMessages.add(List.of(messages));
    return replies.removeAt(0);
  }
}

ModelReply _reply(String text) => ModelReply(content: text);

AgentMessage _user(String text) =>
    AgentMessage(role: MessageRole.user, content: text);

AgentMessage _assistant(String text) =>
    AgentMessage(role: MessageRole.assistant, content: text);

/// Long deterministic filler body so the transcript has foldable exchanges.
String _filler(String tag, {int chars = 400}) => '$tag${'对话内容' * (chars ~/ 4)}';

/// Five exchange groups: one more than the compactor's default tail of 4,
/// so the oldest group is always folded and the summarizer is invoked.
List<AgentMessage> _transcript() => [
      _user(_filler('任务1')),
      _assistant(_filler('回复1')),
      _user(_filler('任务2')),
      _assistant(_filler('回复2')),
      _user('最后一条'),
    ];

const _mainConfig = ModelConfig(
  baseUrl: 'https://api.main.example/v1',
  apiKey: 'sk-main',
  model: 'main-model',
  contextWindow: 100000,
);

const _auxConfig = ModelConfig(
  baseUrl: 'https://api.aux.example/v1',
  model: 'aux-model', // no key: lightweight jobs inherit the main key
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('aux model persistence', () {
    test('defaults are off with an empty record', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      expect(store.auxEnabled, isFalse);
      final aux = store.loadAuxModelConfig();
      expect(aux.baseUrl, isEmpty);
      expect(aux.model, isEmpty);
      expect(aux.isComplete, isFalse);
    });

    test('record and switch round-trip through prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      await store.saveAuxModelConfig(const ModelConfig(
        baseUrl: 'https://api.siliconflow.cn/v1',
        apiKey: 'sk-aux',
        model: 'Qwen/Qwen2.5-7B-Instruct',
        contextWindow: 32768,
      ));
      await store.setAuxEnabled(true);

      final reloaded = store.loadAuxModelConfig();
      expect(reloaded.baseUrl, 'https://api.siliconflow.cn/v1');
      expect(reloaded.apiKey, 'sk-aux');
      expect(reloaded.model, 'Qwen/Qwen2.5-7B-Instruct');
      expect(reloaded.contextWindow, 32768);
      expect(reloaded.isComplete, isTrue);
      expect(store.auxEnabled, isTrue);

      await store.setAuxEnabled(false);
      expect(store.auxEnabled, isFalse);
    });

    test('saving a config alone leaves the switch off', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      await store.saveAuxModelConfig(_auxConfig);

      expect(store.auxEnabled, isFalse);
      expect(store.loadAuxModelConfig().model, 'aux-model');
    });
  });

  group('context compactor summary routing (chat_session)', () {
    test('summarizes through the aux gateway when enabled and complete',
        () async {
      final main = _ScriptedGateway([_reply('主模型摘要')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      final compactor = contextCompactorFor(
        config: _mainConfig,
        auxConfig: _auxConfig,
        auxEnabled: true,
        mainGateway: main,
        auxGateway: aux,
      );

      final result = await compactor!.compact(_transcript());

      expect(result.usedModelSummary, isTrue);
      expect(
        result.messages.any((m) => m.content.contains('辅助模型摘要')),
        isTrue,
      );
      // The folded transcript reached the aux gateway; the main gateway
      // produced nothing.
      expect(aux.seenMessages, hasLength(1));
      expect(
        aux.seenMessages.single.any((m) => m.content.contains('任务1')),
        isTrue,
      );
      expect(main.seenMessages, isEmpty);
    });

    test('stays on the main gateway when the switch is off', () async {
      final main = _ScriptedGateway([_reply('主模型摘要')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      final compactor = contextCompactorFor(
        config: _mainConfig,
        auxConfig: _auxConfig,
        auxEnabled: false,
        mainGateway: main,
        auxGateway: aux,
      );

      final result = await compactor!.compact(_transcript());

      expect(result.usedModelSummary, isTrue);
      expect(
        result.messages.any((m) => m.content.contains('主模型摘要')),
        isTrue,
      );
      expect(main.seenMessages, hasLength(1));
      expect(aux.seenMessages, isEmpty);
    });

    test('stays on the main gateway when the aux record is incomplete',
        () async {
      final main = _ScriptedGateway([_reply('主模型摘要')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      final compactor = contextCompactorFor(
        config: _mainConfig,
        auxConfig: const ModelConfig(baseUrl: 'https://api.aux.example/v1'),
        auxEnabled: true, // no model name: the record is unusable
        mainGateway: main,
        auxGateway: aux,
      );

      final result = await compactor!.compact(_transcript());

      expect(result.usedModelSummary, isTrue);
      expect(main.seenMessages, hasLength(1));
      expect(aux.seenMessages, isEmpty);
    });

    test('no main model configured keeps demo mode compact-free', () {
      final main = _ScriptedGateway([_reply('演示')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      expect(
        contextCompactorFor(
          config: const ModelConfig(),
          auxConfig: _auxConfig,
          auxEnabled: true,
          mainGateway: main,
          auxGateway: aux,
        ),
        isNull,
      );
      expect(main.seenMessages, isEmpty);
      expect(aux.seenMessages, isEmpty);
    });
  });

  group('oversized tool digest routing', () {
    test('digest runs on the aux gateway when enabled and complete', () async {
      final main = _ScriptedGateway([_reply('主模型摘要')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      final summarizer = toolDigestSummarizerFor(
        config: _mainConfig,
        auxConfig: _auxConfig,
        auxEnabled: true,
        mainGateway: main,
        auxGateway: aux,
      );

      final digest = await summarizer!('命令输出' * 500);

      expect(digest, '辅助模型摘要');
      expect(aux.seenMessages, hasLength(1));
      expect(aux.seenMessages.single.last.content, contains('命令输出'));
      expect(main.seenMessages, isEmpty);
    });

    test('digest stays on the main gateway when the switch is off', () async {
      final main = _ScriptedGateway([_reply('主模型摘要')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      final summarizer = toolDigestSummarizerFor(
        config: _mainConfig,
        auxConfig: _auxConfig,
        auxEnabled: false,
        mainGateway: main,
        auxGateway: aux,
      );

      final digest = await summarizer!('命令输出' * 500);

      expect(digest, '主模型摘要');
      expect(main.seenMessages, hasLength(1));
      expect(aux.seenMessages, isEmpty);
    });

    test('no digest at all without a main model', () {
      final main = _ScriptedGateway([_reply('演示')]);
      final aux = _ScriptedGateway([_reply('辅助模型摘要')]);

      expect(
        toolDigestSummarizerFor(
          config: const ModelConfig(),
          auxConfig: _auxConfig,
          auxEnabled: true,
          mainGateway: main,
          auxGateway: aux,
        ),
        isNull,
      );
    });
  });
}
