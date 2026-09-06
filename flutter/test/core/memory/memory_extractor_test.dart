import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/memory/memory_extractor.dart';
import 'package:shelly_hermes/core/models.dart';

/// Gateway stub that replays canned replies and records every request, so
/// tests can assert on the extraction prompt (same pattern as the scripted
/// gateways in test/state).
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

class _ThrowingGateway implements ModelGateway {
  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async =>
      throw StateError('gateway down');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryExtractor parsing', () {
    test('reads a plain JSON array', () {
      final gateway = _ScriptedGateway([]);
      final extractor = MemoryExtractor(gateway: gateway);

      expect(
        extractor.parseFacts('["用户偏好简洁的中文回复","用户在上海工作"]'),
        ['用户偏好简洁的中文回复', '用户在上海工作'],
      );
      expect(gateway.seenMessages, isEmpty);
    });

    test('reads a fenced ```json block', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts('```json\n["用户喜欢茶", "用户养猫"]\n```'),
        ['用户喜欢茶', '用户养猫'],
      );
    });

    test('reads an array embedded in surrounding prose', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts(
          '好的,以下是我提取到的长期记忆:\n["用户偏好简洁回复"]\n希望对你有帮助!',
        ),
        ['用户偏好简洁回复'],
      );
    });

    test('reads an array wrapped in an object', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts('{"facts":["用户在杭州工作"]}'),
        ['用户在杭州工作'],
      );
    });

    test('tolerates map-shaped items and drops non-string entries', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts('[{"text":"用户用左手写字"}, 42, null, "用户凌晨效率高"]'),
        ['用户用左手写字', '用户凌晨效率高'],
      );
    });

    test('keeps at most 3 facts per round', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts('["一","二","三","四"]'),
        ['一', '二', '三'],
      );
    });

    test('drops blank and overly long facts', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(
        extractor.parseFacts('["", "   ", "${'长' * 301}"]'),
        isEmpty,
      );
    });

    test('garbage, empty and object-without-list replies yield nothing', () {
      final extractor = MemoryExtractor(gateway: _ScriptedGateway([]));

      expect(extractor.parseFacts('我觉得这轮对话没什么值得记住的。'), isEmpty);
      expect(extractor.parseFacts(''), isEmpty);
      expect(extractor.parseFacts('{"summary":"用户问天气"}'), isEmpty);
    });
  });

  group('MemoryExtractor.extract', () {
    test('sends the round pair to the model and returns its facts',
        () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '["用户偏好简洁的中文回复"]'),
      ]);
      final extractor = MemoryExtractor(gateway: gateway);

      final facts = await extractor.extract(
        userText: '回答尽量简短一点',
        assistantText: '好的,之后我都用短句回复。',
      );

      expect(facts, ['用户偏好简洁的中文回复']);
      expect(gateway.seenMessages, hasLength(1));
      final prompt = gateway.seenMessages.single;
      expect(prompt.first.role, MessageRole.system);
      expect(prompt.last.content, contains('回答尽量简短一点'));
      expect(prompt.last.content, contains('之后我都用短句回复'));
    });

    test('an empty pair never reaches the model', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '["不该被问到"]'),
      ]);
      final extractor = MemoryExtractor(gateway: gateway);

      expect(
        await extractor.extract(userText: '', assistantText: '有回复'),
        isEmpty,
      );
      expect(
        await extractor.extract(userText: '有输入', assistantText: '  '),
        isEmpty,
      );
      expect(gateway.seenMessages, isEmpty);
    });

    test('every gateway failure resolves to an empty list', () async {
      final extractor = MemoryExtractor(gateway: _ThrowingGateway());

      expect(
        await extractor.extract(userText: '用户的话', assistantText: '助手的话'),
        isEmpty,
      );
    });
  });
}
